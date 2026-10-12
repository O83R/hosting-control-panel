package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

//go:embed web/*
var webFS embed.FS

const (
	passwordIterations = 600000
	sessionTTL         = 8 * time.Hour
	lockoutThreshold   = 5
	lockoutDuration    = 15 * time.Minute
)

type Snapshot struct {
	SchemaVersion  int              `json:"schema_version"`
	GeneratedAt    string           `json:"generated_at"`
	Metadata       map[string]any   `json:"metadata"`
	Host           map[string]any   `json:"host"`
	Infrastructure []map[string]any `json:"infrastructure"`
	Projects       []map[string]any `json:"projects"`
	Backups        map[string]any   `json:"backups"`
	Storage        map[string]any   `json:"storage"`
	RootDocker     map[string]any   `json:"root_docker,omitempty"`
	Diagnostics    []map[string]any `json:"diagnostics"`
	Alerts         []map[string]any `json:"alerts"`
}

type AuditEvent struct {
	ID          int64  `json:"id"`
	OccurredAt  string `json:"occurred_at"`
	Actor       string `json:"actor"`
	Role        string `json:"role"`
	Action      string `json:"action"`
	Scope       string `json:"scope"`
	ProjectID   string `json:"project_id,omitempty"`
	Result      string `json:"result"`
	RequestID   string `json:"request_id"`
	Source      string `json:"source"`
	DetailsJSON string `json:"details_json"`
}

type Session struct {
	UserID    int64
	Username  string
	Role      string
	CSRFToken string
	ExpiresAt time.Time
}

func snapshotPath() string {
	if p := os.Getenv("HOST_SNAPSHOT"); p != "" {
		return p
	}
	return "/data/host-snapshot.json"
}
func auditDBPath() string {
	if p := os.Getenv("AUDIT_DB"); p != "" {
		return p
	}
	return "/var/lib/panel/audit.sqlite"
}
func authDBPath() string {
	if p := os.Getenv("AUTH_DB"); p != "" {
		return p
	}
	return "/var/lib/panel/auth.sqlite"
}
func cookieSecure() bool {
	return strings.EqualFold(os.Getenv("PANEL_COOKIE_SECURE"), "true")
}

func loadSnapshot() (Snapshot, error) {
	var s Snapshot
	b, err := os.ReadFile(snapshotPath())
	if err != nil {
		return s, err
	}
	if err := json.Unmarshal(b, &s); err != nil {
		return s, err
	}
	if s.SchemaVersion != 5 {
		return s, errors.New("unsupported snapshot schema")
	}
	md := s.Metadata
	if md == nil || md["contract_name"] != "hosting-panel-snapshot" || md["contract_version"] != "5.0" {
		return s, errors.New("unsupported snapshot contract")
	}
	return s, nil
}

func sqlite(args ...string) ([]byte, error) {
	cmd := exec.Command("sqlite3", args...)
	return cmd.CombinedOutput()
}

func initDatabases() error {
	if err := os.MkdirAll("/var/lib/panel", 0750); err != nil {
		return err
	}
	auditSchema := `
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS audit_schema_version (
  version INTEGER NOT NULL PRIMARY KEY,
  applied_at TEXT NOT NULL
);
INSERT OR IGNORE INTO audit_schema_version(version, applied_at)
VALUES (1, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
CREATE TABLE IF NOT EXISTS audit_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  occurred_at TEXT NOT NULL,
  actor TEXT NOT NULL,
  role TEXT NOT NULL,
  action TEXT NOT NULL,
  scope TEXT NOT NULL,
  project_id TEXT,
  result TEXT NOT NULL,
  request_id TEXT NOT NULL,
  source TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_audit_events_occurred_at ON audit_events(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_action ON audit_events(action);
CREATE INDEX IF NOT EXISTS idx_audit_events_project_id ON audit_events(project_id);`
	if out, err := sqlite(auditDBPath(), auditSchema); err != nil {
		return errors.New(strings.TrimSpace(string(out)))
	}

	authSchema := `
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS auth_schema_version (
  version INTEGER NOT NULL PRIMARY KEY,
  applied_at TEXT NOT NULL
);
INSERT OR IGNORE INTO auth_schema_version(version, applied_at)
VALUES (1, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  password_salt TEXT NOT NULL,
  password_iterations INTEGER NOT NULL,
  role TEXT NOT NULL,
  is_active INTEGER NOT NULL DEFAULT 1,
  failed_attempts INTEGER NOT NULL DEFAULT 0,
  locked_until TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_login_at TEXT
);
CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL,
  csrf_token TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);
CREATE TABLE IF NOT EXISTS user_project_access (
  user_id INTEGER NOT NULL,
  project_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(user_id, project_id),
  FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_user_project_access_project_id
  ON user_project_access(project_id);
INSERT OR IGNORE INTO auth_schema_version(version, applied_at)
VALUES (2, strftime('%Y-%m-%dT%H:%M:%fZ','now'));`
	if out, err := sqlite(authDBPath(), authSchema); err != nil {
		return errors.New(strings.TrimSpace(string(out)))
	}
	_, _ = sqlite(authDBPath(), `DELETE FROM sessions WHERE expires_at <= strftime('%Y-%m-%dT%H:%M:%fZ','now');`)
	return nil
}

func sqlQuote(v string) string { return "'" + strings.ReplaceAll(v, "'", "''") + "'" }
func requestID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return hex.EncodeToString(b[:])
}
func randomToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
func shaToken(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func appendAudit(actor, role, action, scope, projectID, result, source string, details map[string]any) error {
	raw, err := json.Marshal(details)
	if err != nil {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	projectSQL := "NULL"
	if projectID != "" {
		projectSQL = sqlQuote(projectID)
	}
	q := `INSERT INTO audit_events
(occurred_at,actor,role,action,scope,project_id,result,request_id,source,details_json)
VALUES (` +
		sqlQuote(now) + "," + sqlQuote(actor) + "," + sqlQuote(role) + "," +
		sqlQuote(action) + "," + sqlQuote(scope) + "," + projectSQL + "," +
		sqlQuote(result) + "," + sqlQuote(requestID()) + "," + sqlQuote(source) + "," +
		sqlQuote(string(raw)) + ");"
	out, err := sqlite(auditDBPath(), q)
	if err != nil {
		return errors.New(strings.TrimSpace(string(out)))
	}
	return nil
}

func auditMeta() (map[string]any, error) {
	q := `SELECT json_object(
'db_schema_version',(SELECT max(version) FROM audit_schema_version),
'event_count',(SELECT count(*) FROM audit_events),
'latest_event_at',(SELECT max(occurred_at) FROM audit_events)
);`
	out, err := sqlite("-readonly", "-noheader", auditDBPath(), q)
	if err != nil {
		return nil, errors.New(strings.TrimSpace(string(out)))
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(out))), &v); err != nil {
		return nil, err
	}
	v["storage"] = "sqlite"
	v["mode"] = "append-only-internal"
	return v, nil
}

func listAudit(limit int) ([]AuditEvent, error) {
	if limit < 1 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}
	q := `SELECT json_group_array(json_object(
'id',id,'occurred_at',occurred_at,'actor',actor,'role',role,'action',action,
'scope',scope,'project_id',coalesce(project_id,''),'result',result,
'request_id',request_id,'source',source,'details_json',details_json
)) FROM (
SELECT id,occurred_at,actor,role,action,scope,project_id,result,request_id,source,details_json
FROM audit_events ORDER BY id DESC LIMIT ` + strconv.Itoa(limit) + `);`
	out, err := sqlite("-readonly", "-noheader", auditDBPath(), q)
	if err != nil {
		return nil, errors.New(strings.TrimSpace(string(out)))
	}
	raw := strings.TrimSpace(string(out))
	if raw == "" || raw == "null" {
		return []AuditEvent{}, nil
	}
	var events []AuditEvent
	if err := json.Unmarshal([]byte(raw), &events); err != nil {
		return nil, err
	}
	return events, nil
}

// PBKDF2-HMAC-SHA256 implemented with stdlib only.
func pbkdf2SHA256(password, salt []byte, iterations, keyLen int) []byte {
	hLen := 32
	numBlocks := (keyLen + hLen - 1) / hLen
	out := make([]byte, 0, numBlocks*hLen)
	for block := 1; block <= numBlocks; block++ {
		mac := hmac.New(sha256.New, password)
		mac.Write(salt)
		mac.Write([]byte{byte(block >> 24), byte(block >> 16), byte(block >> 8), byte(block)})
		u := mac.Sum(nil)
		t := append([]byte(nil), u...)
		for i := 1; i < iterations; i++ {
			mac = hmac.New(sha256.New, password)
			mac.Write(u)
			u = mac.Sum(nil)
			for j := range t {
				t[j] ^= u[j]
			}
		}
		out = append(out, t...)
	}
	return out[:keyLen]
}

func passwordRecord(password string) (hashB64, saltB64 string, err error) {
	salt := make([]byte, 16)
	if _, err = rand.Read(salt); err != nil {
		return "", "", err
	}
	dk := pbkdf2SHA256([]byte(password), salt, passwordIterations, 32)
	return base64.RawStdEncoding.EncodeToString(dk), base64.RawStdEncoding.EncodeToString(salt), nil
}

func adminBootstrap(username, password string, reset bool) error {
	username = strings.TrimSpace(strings.ToLower(username))
	if username == "" || len(username) > 64 {
		return errors.New("invalid username")
	}
	if len(password) < 14 {
		return errors.New("password must be at least 14 characters")
	}
	hashB64, saltB64, err := passwordRecord(password)
	if err != nil {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if reset {
		q := `UPDATE users SET password_hash=` + sqlQuote(hashB64) +
			`,password_salt=` + sqlQuote(saltB64) +
			`,password_iterations=` + strconv.Itoa(passwordIterations) +
			`,failed_attempts=0,locked_until=NULL,updated_at=` + sqlQuote(now) +
			` WHERE username=` + sqlQuote(username) + `;`
		out, err := sqlite(authDBPath(), q)
		if err != nil {
			return errors.New(strings.TrimSpace(string(out)))
		}
		return nil
	}
	q := `INSERT OR IGNORE INTO users
(username,password_hash,password_salt,password_iterations,role,is_active,created_at,updated_at)
VALUES (` + sqlQuote(username) + "," + sqlQuote(hashB64) + "," + sqlQuote(saltB64) + "," +
		strconv.Itoa(passwordIterations) + ",'super_admin',1," + sqlQuote(now) + "," + sqlQuote(now) + ");"
	out, err := sqlite(authDBPath(), q)
	if err != nil {
		return errors.New(strings.TrimSpace(string(out)))
	}
	return nil
}

func authMeta() (map[string]any, error) {
	q := `SELECT json_object(
'db_schema_version',(SELECT max(version) FROM auth_schema_version),
'user_count',(SELECT count(*) FROM users),
'active_user_count',(SELECT count(*) FROM users WHERE is_active=1),
'session_count',(SELECT count(*) FROM sessions WHERE expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);`
	out, err := sqlite("-readonly", "-noheader", authDBPath(), q)
	if err != nil {
		return nil, errors.New(strings.TrimSpace(string(out)))
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(out))), &v); err != nil {
		return nil, err
	}
	v["mode"] = "local"
	v["password_kdf"] = "PBKDF2-HMAC-SHA256"
	v["password_iterations"] = passwordIterations
	v["session_ttl_hours"] = 8
	v["cookie_secure"] = cookieSecure()
	return v, nil
}

func userForLogin(username string) (map[string]any, error) {
	q := `SELECT json_object(
'id',id,'username',username,'password_hash',password_hash,'password_salt',password_salt,
'password_iterations',password_iterations,'role',role,'is_active',is_active,
'failed_attempts',failed_attempts,'locked_until',coalesce(locked_until,'')
) FROM users WHERE username=` + sqlQuote(strings.ToLower(strings.TrimSpace(username))) + ` LIMIT 1;`
	out, err := sqlite("-readonly", "-noheader", authDBPath(), q)
	if err != nil {
		return nil, err
	}
	raw := strings.TrimSpace(string(out))
	if raw == "" {
		return nil, errors.New("not found")
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		return nil, err
	}
	return v, nil
}

func verifyPassword(password string, u map[string]any) bool {
	hashB64, _ := u["password_hash"].(string)
	saltB64, _ := u["password_salt"].(string)
	it := int(u["password_iterations"].(float64))
	want, err1 := base64.RawStdEncoding.DecodeString(hashB64)
	salt, err2 := base64.RawStdEncoding.DecodeString(saltB64)
	if err1 != nil || err2 != nil || it < 1 {
		return false
	}
	got := pbkdf2SHA256([]byte(password), salt, it, len(want))
	return subtle.ConstantTimeCompare(got, want) == 1
}

func recordFailedLogin(userID int64, attempts int) {
	attempts++
	lockSQL := "NULL"
	if attempts >= lockoutThreshold {
		lockSQL = sqlQuote(time.Now().UTC().Add(lockoutDuration).Format(time.RFC3339Nano))
		attempts = 0
	}
	q := `UPDATE users SET failed_attempts=` + strconv.Itoa(attempts) + `,locked_until=` + lockSQL +
		`,updated_at=` + sqlQuote(time.Now().UTC().Format(time.RFC3339Nano)) +
		` WHERE id=` + strconv.FormatInt(userID, 10) + `;`
	_, _ = sqlite(authDBPath(), q)
}

func createSession(userID int64) (token, csrf string, err error) {
	token, err = randomToken(32)
	if err != nil {
		return "", "", err
	}
	csrf, err = randomToken(24)
	if err != nil {
		return "", "", err
	}
	now := time.Now().UTC()
	exp := now.Add(sessionTTL)
	q := `INSERT INTO sessions(token_hash,user_id,csrf_token,created_at,expires_at,last_seen_at)
VALUES (` + sqlQuote(shaToken(token)) + "," + strconv.FormatInt(userID, 10) + "," +
		sqlQuote(csrf) + "," + sqlQuote(now.Format(time.RFC3339Nano)) + "," +
		sqlQuote(exp.Format(time.RFC3339Nano)) + "," + sqlQuote(now.Format(time.RFC3339Nano)) + ");"
	out, err := sqlite(authDBPath(), q)
	if err != nil {
		return "", "", errors.New(strings.TrimSpace(string(out)))
	}
	return token, csrf, nil
}

func sessionFromRequest(r *http.Request) (*Session, error) {
	c, err := r.Cookie("panel_session")
	if err != nil || c.Value == "" {
		return nil, errors.New("no session")
	}
	q := `SELECT json_object(
'user_id',u.id,'username',u.username,'role',u.role,'csrf_token',s.csrf_token,'expires_at',s.expires_at
) FROM sessions s JOIN users u ON u.id=s.user_id
WHERE s.token_hash=` + sqlQuote(shaToken(c.Value)) + `
AND u.is_active=1 AND s.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now') LIMIT 1;`
	out, err := sqlite("-readonly", "-noheader", authDBPath(), q)
	if err != nil {
		return nil, err
	}
	raw := strings.TrimSpace(string(out))
	if raw == "" {
		return nil, errors.New("invalid session")
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		return nil, err
	}
	exp, err := time.Parse(time.RFC3339Nano, v["expires_at"].(string))
	if err != nil {
		return nil, err
	}
	return &Session{
		UserID:    int64(v["user_id"].(float64)),
		Username:  v["username"].(string),
		Role:      v["role"].(string),
		CSRFToken: v["csrf_token"].(string),
		ExpiresAt: exp,
	}, nil
}

func deleteSession(r *http.Request) {
	if c, err := r.Cookie("panel_session"); err == nil && c.Value != "" {
		_, _ = sqlite(authDBPath(), `DELETE FROM sessions WHERE token_hash=`+sqlQuote(shaToken(c.Value))+`;`)
	}
}

func setSessionCookie(w http.ResponseWriter, token string) {
	http.SetCookie(w, &http.Cookie{
		Name: "panel_session", Value: token, Path: "/",
		HttpOnly: true, Secure: cookieSecure(), SameSite: http.SameSiteStrictMode,
		MaxAge: int(sessionTTL.Seconds()),
	})
}
func clearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name: "panel_session", Value: "", Path: "/",
		HttpOnly: true, Secure: cookieSecure(), SameSite: http.SameSiteStrictMode,
		MaxAge: -1, Expires: time.Unix(1, 0),
	})
}

func validRole(role string) bool {
	switch role {
	case "super_admin", "project_admin", "viewer":
		return true
	default:
		return false
	}
}

func capabilitiesForRole(role string) []string {
	switch role {
	case "super_admin":
		return []string{"*"}
	case "project_admin":
		return []string{"projects.read", "project.actions.future"}
	case "viewer":
		return []string{"projects.read"}
	default:
		return []string{}
	}
}

func assignedProjects(userID int64) ([]string, error) {
	q := `SELECT json_group_array(project_id) FROM (
SELECT project_id FROM user_project_access
WHERE user_id=` + strconv.FormatInt(userID, 10) + `
ORDER BY project_id);`
	out, err := sqlite("-readonly", "-noheader", authDBPath(), q)
	if err != nil {
		return nil, errors.New(strings.TrimSpace(string(out)))
	}
	raw := strings.TrimSpace(string(out))
	if raw == "" || raw == "null" {
		return []string{}, nil
	}
	var ids []string
	if err := json.Unmarshal([]byte(raw), &ids); err != nil {
		return nil, err
	}
	return ids, nil
}

func projectSet(ids []string) map[string]bool {
	m := make(map[string]bool, len(ids))
	for _, id := range ids {
		m[id] = true
	}
	return m
}

func filteredSnapshot(s Snapshot, sess *Session) (Snapshot, error) {
	if sess.Role == "super_admin" {
		return s, nil
	}
	ids, err := assignedProjects(sess.UserID)
	if err != nil {
		return Snapshot{}, err
	}
	allowed := projectSet(ids)

	filteredProjects := make([]map[string]any, 0)
	for _, p := range s.Projects {
		id, _ := p["id"].(string)
		if allowed[id] {
			filteredProjects = append(filteredProjects, p)
		}
	}

	filteredDiagnostics := make([]map[string]any, 0)
	for _, d := range s.Diagnostics {
		pid, _ := d["project"].(string)
		if pid != "" && allowed[pid] {
			filteredDiagnostics = append(filteredDiagnostics, d)
		}
	}

	filteredAlerts := make([]map[string]any, 0)
	for _, a := range s.Alerts {
		scope, _ := a["scope"].(string)
		pid, _ := a["project_id"].(string)
		if scope == "project" && allowed[pid] {
			filteredAlerts = append(filteredAlerts, a)
		}
	}

	// Non-super-admin users get project-scoped operational data only.
	s.Projects = filteredProjects
	s.Infrastructure = []map[string]any{}
	s.Backups = map[string]any{}
	s.Storage = map[string]any{}
	s.RootDocker = map[string]any{}
	s.Diagnostics = filteredDiagnostics
	s.Alerts = filteredAlerts
	s.Host = map[string]any{
		"status":   s.Host["status"],
		"hostname": s.Host["hostname"],
	}
	return s, nil
}

func requireRole(allowed ...string) func(http.Handler) http.Handler {
	set := map[string]bool{}
	for _, r := range allowed {
		set[r] = true
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			sess, err := sessionFromRequest(r)
			if err != nil {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
				return
			}
			if !set[sess.Role] {
				writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func rbacMeta() (map[string]any, error) {
	q := `SELECT json_object(
'db_schema_version',(SELECT max(version) FROM auth_schema_version),
'user_count',(SELECT count(*) FROM users),
'super_admin_count',(SELECT count(*) FROM users WHERE role='super_admin' AND is_active=1),
'project_admin_count',(SELECT count(*) FROM users WHERE role='project_admin' AND is_active=1),
'viewer_count',(SELECT count(*) FROM users WHERE role='viewer' AND is_active=1),
'assignment_count',(SELECT count(*) FROM user_project_access)
);`
	out, err := sqlite("-readonly", "-noheader", authDBPath(), q)
	if err != nil {
		return nil, errors.New(strings.TrimSpace(string(out)))
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(out))), &v); err != nil {
		return nil, err
	}
	v["roles"] = []string{"super_admin", "project_admin", "viewer"}
	v["mode"] = "project_scoped"
	return v, nil
}

func listUsers() ([]map[string]any, error) {
	q := `SELECT json_group_array(json_object(
'id',u.id,
'username',u.username,
'role',u.role,
'is_active',u.is_active,
'created_at',u.created_at,
'last_login_at',coalesce(u.last_login_at,''),
'projects',json(COALESCE((
  SELECT json_group_array(project_id) FROM (
    SELECT project_id FROM user_project_access
    WHERE user_id=u.id ORDER BY project_id
  )
),'[]'))
)) FROM users u ORDER BY u.username;`
	out, err := sqlite("-readonly", "-noheader", authDBPath(), q)
	if err != nil {
		return nil, errors.New(strings.TrimSpace(string(out)))
	}
	raw := strings.TrimSpace(string(out))
	if raw == "" || raw == "null" {
		return []map[string]any{}, nil
	}
	var users []map[string]any
	if err := json.Unmarshal([]byte(raw), &users); err != nil {
		return nil, err
	}
	return users, nil
}

func userIDByName(username string) (int64, string, error) {
	q := `SELECT json_object('id',id,'role',role) FROM users WHERE username=` +
		sqlQuote(strings.ToLower(strings.TrimSpace(username))) + ` LIMIT 1;`
	out, err := sqlite("-readonly", "-noheader", authDBPath(), q)
	if err != nil {
		return 0, "", err
	}
	raw := strings.TrimSpace(string(out))
	if raw == "" {
		return 0, "", errors.New("user not found")
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		return 0, "", err
	}
	return int64(v["id"].(float64)), v["role"].(string), nil
}

func createLocalUser(username, role, password string) error {
	username = strings.ToLower(strings.TrimSpace(username))
	role = strings.TrimSpace(role)
	if username == "" || len(username) > 64 {
		return errors.New("invalid username")
	}
	if !validRole(role) || role == "super_admin" {
		return errors.New("CLI user-create supports project_admin or viewer only")
	}
	if len(password) < 14 {
		return errors.New("password must be at least 14 characters")
	}
	hashB64, saltB64, err := passwordRecord(password)
	if err != nil {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	q := `INSERT INTO users
(username,password_hash,password_salt,password_iterations,role,is_active,created_at,updated_at)
VALUES (` + sqlQuote(username) + "," + sqlQuote(hashB64) + "," + sqlQuote(saltB64) + "," +
		strconv.Itoa(passwordIterations) + "," + sqlQuote(role) + ",1," +
		sqlQuote(now) + "," + sqlQuote(now) + ");"
	out, err := sqlite(authDBPath(), q)
	if err != nil {
		return errors.New(strings.TrimSpace(string(out)))
	}
	return appendAudit("system", "system", "rbac.user_create", "rbac", "", "success", "cli",
		map[string]any{"username": username, "role": role})
}

func setUserActive(username string, active bool) error {
	uid, role, err := userIDByName(username)
	if err != nil {
		return err
	}
	if role == "super_admin" && !active {
		return errors.New("super_admin cannot be disabled with this command")
	}
	v := 0
	if active {
		v = 1
	}
	q := `UPDATE users SET is_active=` + strconv.Itoa(v) + `,updated_at=` +
		sqlQuote(time.Now().UTC().Format(time.RFC3339Nano)) +
		` WHERE id=` + strconv.FormatInt(uid, 10) + `;`
	out, err := sqlite(authDBPath(), q)
	if err != nil {
		return errors.New(strings.TrimSpace(string(out)))
	}
	if !active {
		_, _ = sqlite(authDBPath(), `DELETE FROM sessions WHERE user_id=`+strconv.FormatInt(uid, 10)+`;`)
	}
	action := "rbac.user_enable"
	if !active {
		action = "rbac.user_disable"
	}
	return appendAudit("system", "system", action, "rbac", "", "success", "cli",
		map[string]any{"username": strings.ToLower(strings.TrimSpace(username))})
}

func validateProjectID(projectID string) bool {
	s, err := loadSnapshot()
	if err != nil {
		return false
	}
	for _, p := range s.Projects {
		if id, _ := p["id"].(string); id == projectID {
			return true
		}
	}
	return false
}

func assignProject(username, projectID string, add bool) error {
	if !validateProjectID(projectID) {
		return errors.New("unknown project_id")
	}
	uid, role, err := userIDByName(username)
	if err != nil {
		return err
	}
	if role == "super_admin" {
		return errors.New("super_admin does not need project assignments")
	}
	if add {
		q := `INSERT OR IGNORE INTO user_project_access(user_id,project_id,created_at) VALUES (` +
			strconv.FormatInt(uid, 10) + "," + sqlQuote(projectID) + "," +
			sqlQuote(time.Now().UTC().Format(time.RFC3339Nano)) + ");"
		if out, err := sqlite(authDBPath(), q); err != nil {
			return errors.New(strings.TrimSpace(string(out)))
		}
		return appendAudit("system", "system", "rbac.project_assign", "rbac", projectID, "success", "cli",
			map[string]any{"username": strings.ToLower(strings.TrimSpace(username))})
	}
	q := `DELETE FROM user_project_access WHERE user_id=` + strconv.FormatInt(uid, 10) +
		` AND project_id=` + sqlQuote(projectID) + `;`
	if out, err := sqlite(authDBPath(), q); err != nil {
		return errors.New(strings.TrimSpace(string(out)))
	}
	return appendAudit("system", "system", "rbac.project_unassign", "rbac", projectID, "success", "cli",
		map[string]any{"username": strings.ToLower(strings.TrimSpace(username))})
}

type AgentResponse struct {
	ProtocolVersion int            `json:"protocol_version"`
	RequestID       string         `json:"request_id"`
	Action          string         `json:"action"`
	Status          string         `json:"status"`
	Code            string         `json:"code"`
	Message         string         `json:"message"`
	CompletedAt     string         `json:"completed_at"`
	AgentVersion    string         `json:"agent_version"`
	Result          map[string]any `json:"result,omitempty"`
}

func actionsRoot() string {
	if p := os.Getenv("ACTIONS_ROOT"); p != "" {
		return p
	}
	return "/var/lib/actions"
}

func ensureActionDirs() error {
	for _, name := range []string{"inbox", "processing", "outbox", "failed", "staging"} {
		if err := os.MkdirAll(actionsRoot()+"/"+name, 0750); err != nil {
			return err
		}
	}
	return nil
}

func waitAgentResponse(rid, action string, timeout time.Duration) (AgentResponse, error) {
	var zero AgentResponse
	deadline := time.Now().Add(timeout)
	outbox := actionsRoot() + "/outbox/" + rid + ".json"
	for time.Now().Before(deadline) {
		b, err := os.ReadFile(outbox)
		if err == nil {
			_ = os.Remove(outbox)
			var resp AgentResponse
			if err := json.Unmarshal(b, &resp); err != nil {
				return zero, err
			}
			if resp.RequestID != rid || resp.Action != action {
				return zero, errors.New("agent response mismatch")
			}
			return resp, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return zero, err
		}
		time.Sleep(100 * time.Millisecond)
	}
	return zero, errors.New("agent response timeout")
}

func submitAgentRequest(actor, role, action, projectID string, parameters map[string]any, timeout time.Duration) (AgentResponse, error) {
	var zero AgentResponse
	if role != "super_admin" {
		return zero, errors.New("role not allowed")
	}
	if err := ensureActionDirs(); err != nil {
		return zero, err
	}
	rid := requestID()
	req := map[string]any{
		"protocol_version": 1,
		"request_id":       rid,
		"action":           action,
		"actor":            actor,
		"role":             role,
		"project_id":       projectID,
		"parameters":       parameters,
		"submitted_at":     time.Now().UTC().Format(time.RFC3339Nano),
	}
	raw, err := json.Marshal(req)
	if err != nil {
		return zero, err
	}
	inbox := actionsRoot() + "/inbox/" + rid + ".json"
	tmp := inbox + ".tmp"
	if err := os.WriteFile(tmp, append(raw, '\n'), 0640); err != nil {
		return zero, err
	}
	if err := os.Rename(tmp, inbox); err != nil {
		_ = os.Remove(tmp)
		return zero, err
	}
	return waitAgentResponse(rid, action, timeout)
}

func submitAgentPing(actor, role string) (AgentResponse, error) {
	return submitAgentRequest(actor, role, "agent.ping", "", map[string]any{}, 6*time.Second)
}

func sqliteBackup(src, dst string) error {
	cmd := exec.Command("sqlite3", src, ".backup "+dst)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return errors.New(strings.TrimSpace(string(out)))
	}
	return nil
}

func prepareControlPlaneBackup(rid string) (string, error) {
	staging := actionsRoot() + "/staging/" + rid
	if err := os.MkdirAll(staging, 0750); err != nil {
		return "", err
	}
	cleanup := func() { _ = os.RemoveAll(staging) }

	if err := sqliteBackup(authDBPath(), staging+"/auth.sqlite"); err != nil {
		cleanup()
		return "", err
	}
	if err := sqliteBackup(auditDBPath(), staging+"/audit.sqlite"); err != nil {
		cleanup()
		return "", err
	}

	s, err := loadSnapshot()
	if err != nil {
		cleanup()
		return "", err
	}
	state := map[string]any{
		"panel_version":   "v0.20.1",
		"created_at":      time.Now().UTC().Format(time.RFC3339Nano),
		"snapshot_schema": s.SchemaVersion,
		"snapshot_contract": map[string]any{
			"name":    s.Metadata["contract_name"],
			"version": s.Metadata["contract_version"],
		},
		"note": "control-plane state backup; application project databases are not included",
	}
	raw, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		cleanup()
		return "", err
	}
	if err := os.WriteFile(staging+"/panel_state.json", append(raw, '\n'), 0640); err != nil {
		cleanup()
		return "", err
	}
	return staging, nil
}

func submitControlPlaneBackup(actor, role string) (AgentResponse, error) {
	var zero AgentResponse
	if role != "super_admin" {
		return zero, errors.New("role not allowed")
	}
	if err := ensureActionDirs(); err != nil {
		return zero, err
	}

	rid := requestID()
	staging, err := prepareControlPlaneBackup(rid)
	if err != nil {
		return zero, err
	}
	req := map[string]any{
		"protocol_version": 1,
		"request_id":       rid,
		"action":           "backup.now",
		"actor":            actor,
		"role":             role,
		"project_id":       "hosting-control-panel",
		"parameters":       map[string]any{"scope": "control_plane_state"},
		"submitted_at":     time.Now().UTC().Format(time.RFC3339Nano),
	}
	raw, err := json.Marshal(req)
	if err != nil {
		_ = os.RemoveAll(staging)
		return zero, err
	}
	inbox := actionsRoot() + "/inbox/" + rid + ".json"
	tmp := inbox + ".tmp"
	if err := os.WriteFile(tmp, append(raw, '\n'), 0640); err != nil {
		_ = os.RemoveAll(staging)
		return zero, err
	}
	if err := os.Rename(tmp, inbox); err != nil {
		_ = os.Remove(tmp)
		_ = os.RemoveAll(staging)
		return zero, err
	}
	resp, err := waitAgentResponse(rid, "backup.now", 20*time.Second)
	if err != nil {
		_ = os.RemoveAll(staging)
		return zero, err
	}
	return resp, nil
}

func validProjectID(v string) bool {
	if len(v) < 1 || len(v) > 63 {
		return false
	}
	for i, r := range v {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-'
		if !ok || (i == 0 && r == '-') {
			return false
		}
	}
	return true
}

func submitProjectBackup(actor, role, projectID string) (AgentResponse, error) {
	var zero AgentResponse
	if role != "super_admin" {
		return zero, errors.New("role not allowed")
	}
	if !validProjectID(projectID) {
		return zero, errors.New("invalid project id")
	}
	return submitAgentRequest(
		actor,
		role,
		"project.backup",
		projectID,
		map[string]any{"scope": "database_logical"},
		12*time.Minute,
	)
}

func backupContractPath() string {
	return "/data/project-backup-contract.json"
}

func loadBackupContract() (map[string]any, error) {
	b, err := os.ReadFile(backupContractPath())
	if err != nil {
		return nil, err
	}
	var v map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, err
	}
	if int(v["schema_version"].(float64)) != 1 {
		return nil, errors.New("unsupported backup contract schema")
	}
	return v, nil
}

func backupPreflightPath() string {
	return "/data/project-backup-preflight.json"
}

func loadBackupPreflight() (map[string]any, error) {
	b, err := os.ReadFile(backupPreflightPath())
	if err != nil {
		return nil, err
	}
	var v map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, err
	}
	if int(v["schema_version"].(float64)) != 1 {
		return nil, errors.New("unsupported backup preflight schema")
	}
	return v, nil
}

func backupAdaptersPath() string {
	return "/data/project-backup-adapters.json"
}

func loadBackupAdapters() (map[string]any, error) {
	b, err := os.ReadFile(backupAdaptersPath())
	if err != nil {
		return nil, err
	}
	var v map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, err
	}
	if int(v["schema_version"].(float64)) != 1 {
		return nil, errors.New("unsupported backup adapters schema")
	}
	return v, nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func requireSession(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s, err := sessionFromRequest(r)
		if err != nil {
			if strings.HasPrefix(r.URL.Path, "/api/") {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
			} else {
				http.Redirect(w, r, "/login", http.StatusSeeOther)
			}
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-CSRF-Token")), []byte(s.CSRFToken)) != 1 {
				writeJSON(w, http.StatusForbidden, map[string]string{"error": "csrf validation failed"})
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		w.Header().Set("Content-Security-Policy",
			"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		next.ServeHTTP(w, r)
	})
}

func main() {
	if err := initDatabases(); err != nil {
		log.Fatalf("database init failed: %v", err)
	}
	if err := ensureActionDirs(); err != nil {
		log.Fatalf("actions queue init failed: %v", err)
	}

	if len(os.Args) >= 3 && os.Args[1] == "project-backup-cli" {
		resp, err := submitProjectBackup("system-cli", "super_admin", os.Args[2])
		if err != nil {
			log.Fatal(err)
		}
		b, _ := json.MarshalIndent(resp, "", "  ")
		os.Stdout.Write(b)
		os.Stdout.Write([]byte("\n"))
		if resp.Status != "success" || resp.Code != "OK" {
			os.Exit(2)
		}
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "backup-contract-cli" {
		v, err := loadBackupContract()
		if err != nil {
			log.Fatal(err)
		}
		b, _ := json.MarshalIndent(v, "", "  ")
		os.Stdout.Write(b)
		os.Stdout.Write([]byte("\n"))
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "backup-preflight-cli" {
		v, err := loadBackupPreflight()
		if err != nil {
			log.Fatal(err)
		}
		b, _ := json.MarshalIndent(v, "", "  ")
		os.Stdout.Write(b)
		os.Stdout.Write([]byte("\n"))
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "backup-adapters-cli" {
		v, err := loadBackupAdapters()
		if err != nil {
			log.Fatal(err)
		}
		b, _ := json.MarshalIndent(v, "", "  ")
		os.Stdout.Write(b)
		os.Stdout.Write([]byte("\n"))
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "backup-history-cli" {
		snap, err := loadSnapshot()
		if err != nil {
			log.Fatal(err)
		}
		history := []any{}
		if snap.Backups != nil {
			if raw, ok := snap.Backups["control_plane_history"]; ok {
				if list, ok := raw.([]any); ok {
					history = list
				}
			}
		}
		b, _ := json.MarshalIndent(map[string]any{
			"scope": "control_plane_state",
			"count": len(history),
			"items": history,
		}, "", "  ")
		os.Stdout.Write(b)
		os.Stdout.Write([]byte("\n"))
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "backup-now-cli" {
		resp, err := submitControlPlaneBackup("system-cli", "super_admin")
		if err != nil {
			log.Fatal(err)
		}
		if resp.Status != "success" || resp.Code != "OK" {
			log.Fatalf("backup failed: %s %s", resp.Status, resp.Code)
		}
		b, _ := json.MarshalIndent(resp, "", "  ")
		os.Stdout.Write(b)
		os.Stdout.Write([]byte("\n"))
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "agent-probe" {
		resp, err := submitAgentPing("system-probe", "super_admin")
		if err != nil {
			log.Fatal(err)
		}
		if resp.Status != "success" || resp.Code != "OK" {
			log.Fatalf("agent probe failed: %s %s", resp.Status, resp.Code)
		}
		b, _ := json.MarshalIndent(resp, "", "  ")
		os.Stdout.Write(b)
		os.Stdout.Write([]byte("\n"))
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "user-list" {
		users, err := listUsers()
		if err != nil {
			log.Fatal(err)
		}
		b, _ := json.MarshalIndent(users, "", "  ")
		os.Stdout.Write(b)
		os.Stdout.Write([]byte("\n"))
		return
	}
	if len(os.Args) >= 4 && os.Args[1] == "user-create" {
		pw, err := io.ReadAll(io.LimitReader(os.Stdin, 4096))
		if err != nil {
			log.Fatal(err)
		}
		if err := createLocalUser(os.Args[2], os.Args[3], strings.TrimSpace(string(pw))); err != nil {
			log.Fatal(err)
		}
		log.Printf("user created: %s role=%s", os.Args[2], os.Args[3])
		return
	}
	if len(os.Args) >= 3 && (os.Args[1] == "user-disable" || os.Args[1] == "user-enable") {
		if err := setUserActive(os.Args[2], os.Args[1] == "user-enable"); err != nil {
			log.Fatal(err)
		}
		log.Printf("%s: %s", os.Args[1], os.Args[2])
		return
	}
	if len(os.Args) >= 4 && (os.Args[1] == "user-assign" || os.Args[1] == "user-unassign") {
		if err := assignProject(os.Args[2], os.Args[3], os.Args[1] == "user-assign"); err != nil {
			log.Fatal(err)
		}
		log.Printf("%s: %s -> %s", os.Args[1], os.Args[2], os.Args[3])
		return
	}
	if len(os.Args) >= 3 && (os.Args[1] == "admin-bootstrap" || os.Args[1] == "admin-reset") {
		pw, err := io.ReadAll(io.LimitReader(os.Stdin, 4096))
		if err != nil {
			log.Fatal(err)
		}
		password := strings.TrimSpace(string(pw))
		reset := os.Args[1] == "admin-reset"
		if err := adminBootstrap(os.Args[2], password, reset); err != nil {
			log.Fatal(err)
		}
		if reset {
			_ = appendAudit(os.Args[2], "super_admin", "auth.password_reset", "auth", "", "success", "cli", map[string]any{})
			log.Printf("admin password reset: %s", os.Args[2])
		} else {
			_ = appendAudit(os.Args[2], "super_admin", "auth.bootstrap", "auth", "", "success", "cli", map[string]any{})
			log.Printf("admin bootstrap complete: %s", os.Args[2])
		}
		return
	}

	_ = appendAudit("system", "system", "panel.start", "panel", "", "success", "internal",
		map[string]any{"version": "v0.20.1", "mode": "authenticated-control-plane"})

	public := http.NewServeMux()
	protected := http.NewServeMux()

	public.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		s, serr := loadSnapshot()
		am, aerr := auditMeta()
		authm, uerr := authMeta()
		if serr != nil || aerr != nil || uerr != nil {
			writeJSON(w, 503, map[string]any{"status": "degraded"})
			return
		}
		writeJSON(w, 200, map[string]any{
			"status": "ok", "mode": "authenticated_control_plane",
			"snapshot": true, "audit": true, "auth": true,
			"schema_version": s.SchemaVersion, "generated_at": s.GeneratedAt,
			"audit_event_count": am["event_count"], "auth_user_count": authm["user_count"],
		})
	})

	public.HandleFunc("GET /api/v1/auth/status", func(w http.ResponseWriter, r *http.Request) {
		m, err := authMeta()
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "auth unavailable"})
			return
		}
		writeJSON(w, 200, m)
	})

	public.HandleFunc("POST /api/v1/auth/login", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Username string `json:"username"`
			Password string `json:"password"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&in); err != nil {
			writeJSON(w, 400, map[string]string{"error": "invalid request"})
			return
		}
		u, err := userForLogin(in.Username)
		if err != nil {
			time.Sleep(250 * time.Millisecond)
			_ = appendAudit(strings.ToLower(strings.TrimSpace(in.Username)), "unknown", "auth.login", "auth", "", "failure", "http", map[string]any{"reason": "invalid_credentials"})
			writeJSON(w, 401, map[string]string{"error": "invalid credentials"})
			return
		}
		uid := int64(u["id"].(float64))
		username := u["username"].(string)
		role := u["role"].(string)
		if int(u["is_active"].(float64)) != 1 {
			_ = appendAudit(username, role, "auth.login", "auth", "", "failure", "http", map[string]any{"reason": "inactive"})
			writeJSON(w, 401, map[string]string{"error": "invalid credentials"})
			return
		}
		if locked, _ := u["locked_until"].(string); locked != "" {
			if t, err := time.Parse(time.RFC3339Nano, locked); err == nil && time.Now().UTC().Before(t) {
				_ = appendAudit(username, role, "auth.login", "auth", "", "failure", "http", map[string]any{"reason": "locked"})
				writeJSON(w, 429, map[string]string{"error": "account temporarily locked"})
				return
			}
		}
		if !verifyPassword(in.Password, u) {
			recordFailedLogin(uid, int(u["failed_attempts"].(float64)))
			_ = appendAudit(username, role, "auth.login", "auth", "", "failure", "http", map[string]any{"reason": "invalid_credentials"})
			writeJSON(w, 401, map[string]string{"error": "invalid credentials"})
			return
		}
		token, csrf, err := createSession(uid)
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "session unavailable"})
			return
		}
		now := time.Now().UTC().Format(time.RFC3339Nano)
		_, _ = sqlite(authDBPath(), `UPDATE users SET failed_attempts=0,locked_until=NULL,last_login_at=`+sqlQuote(now)+`,updated_at=`+sqlQuote(now)+` WHERE id=`+strconv.FormatInt(uid, 10)+`;`)
		setSessionCookie(w, token)
		_ = appendAudit(username, role, "auth.login", "auth", "", "success", "http", map[string]any{})
		writeJSON(w, 200, map[string]any{"username": username, "role": role, "csrf_token": csrf})
	})

	// Login page and public web assets.
	webSub, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatal(err)
	}
	webServer := http.FileServer(http.FS(webSub))
	public.HandleFunc("GET /login", func(w http.ResponseWriter, r *http.Request) {
		if _, err := sessionFromRequest(r); err == nil {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		f, err := webFS.ReadFile("web/login.html")
		if err != nil {
			http.Error(w, "login unavailable", 500)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(f)
	})
	public.Handle("/styles.css", webServer)
	public.Handle("/login.js", webServer)

	protected.HandleFunc("GET /api/v1/auth/me", func(w http.ResponseWriter, r *http.Request) {
		s, _ := sessionFromRequest(r)
		projects, _ := assignedProjects(s.UserID)
		writeJSON(w, 200, map[string]any{
			"username":     s.Username,
			"role":         s.Role,
			"csrf_token":   s.CSRFToken,
			"expires_at":   s.ExpiresAt.Format(time.RFC3339Nano),
			"project_ids":  projects,
			"capabilities": capabilitiesForRole(s.Role),
		})
	})
	protected.HandleFunc("POST /api/v1/auth/logout", func(w http.ResponseWriter, r *http.Request) {
		s, _ := sessionFromRequest(r)
		deleteSession(r)
		clearSessionCookie(w)
		_ = appendAudit(s.Username, s.Role, "auth.logout", "auth", "", "success", "http", map[string]any{})
		writeJSON(w, 200, map[string]bool{"ok": true})
	})
	protected.HandleFunc("POST /api/v1/actions/ping", func(w http.ResponseWriter, r *http.Request) {
		sess, err := sessionFromRequest(r)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
			return
		}
		if sess.Role != "super_admin" {
			_ = appendAudit(sess.Username, sess.Role, "agent.ping", "agent", "", "denied", "http", map[string]any{})
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}
		_ = appendAudit(sess.Username, sess.Role, "agent.ping", "agent", "", "started", "http", map[string]any{})
		resp, err := submitAgentPing(sess.Username, sess.Role)
		if err != nil {
			_ = appendAudit(sess.Username, sess.Role, "agent.ping", "agent", "", "failure", "http", map[string]any{"reason": err.Error()})
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "action agent unavailable"})
			return
		}
		_ = appendAudit(sess.Username, sess.Role, "agent.ping", "agent", "", resp.Status, "http",
			map[string]any{"request_id": resp.RequestID, "agent_version": resp.AgentVersion})
		writeJSON(w, 200, resp)
	})

	protected.HandleFunc("POST /api/v1/actions/project-backup", func(w http.ResponseWriter, r *http.Request) {
		sess, err := sessionFromRequest(r)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
			return
		}
		if sess.Role != "super_admin" {
			_ = appendAudit(sess.Username, sess.Role, "project.backup", "backup", "", "denied", "http", map[string]any{})
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}

		var in struct {
			ProjectID        string `json:"project_id"`
			ConfirmProjectID string `json:"confirm_project_id"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2048)).Decode(&in); err != nil || !validProjectID(in.ProjectID) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid project id"})
			return
		}
		if in.ConfirmProjectID != in.ProjectID {
			_ = appendAudit(sess.Username, sess.Role, "project.backup", "backup", in.ProjectID, "denied", "http",
				map[string]any{"reason": "confirmation_mismatch"})
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "project confirmation mismatch"})
			return
		}

		snap, err := loadSnapshot()
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "snapshot unavailable"})
			return
		}
		registered := false
		running := false
		for _, p := range snap.Projects {
			id, _ := p["id"].(string)
			if id != in.ProjectID {
				continue
			}
			registered = true
			status, _ := p["status"].(string)
			deployment, _ := p["deployment_state"].(string)
			running = status == "online" && deployment == "running_deployed"
			break
		}
		if !registered {
			_ = appendAudit(sess.Username, sess.Role, "project.backup", "backup", in.ProjectID, "denied", "http",
				map[string]any{"reason": "project_not_registered"})
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "project is not registered"})
			return
		}
		if !running {
			_ = appendAudit(sess.Username, sess.Role, "project.backup", "backup", in.ProjectID, "denied", "http",
				map[string]any{"reason": "project_not_running"})
			writeJSON(w, http.StatusConflict, map[string]string{"error": "project is not running"})
			return
		}

		// Project database backups can legitimately take longer than the server-wide
		// default write timeout. Extend the deadline only for this explicit action.
		_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(13 * time.Minute))

		_ = appendAudit(sess.Username, sess.Role, "project.backup", "backup", in.ProjectID, "started", "http",
			map[string]any{"scope": "database_logical"})

		resp, err := submitProjectBackup(sess.Username, sess.Role, in.ProjectID)
		if err != nil {
			_ = appendAudit(sess.Username, sess.Role, "project.backup", "backup", in.ProjectID, "failure", "http",
				map[string]any{"scope": "database_logical", "reason": err.Error()})
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "project backup action unavailable"})
			return
		}

		details := map[string]any{
			"request_id":    resp.RequestID,
			"agent_version": resp.AgentVersion,
			"scope":         "database_logical",
		}
		if resp.Result != nil {
			for _, key := range []string{"archive_path", "archive_sha256", "engine", "logical_validation", "dump_size_bytes"} {
				if v, ok := resp.Result[key]; ok {
					details[key] = v
				}
			}
		}
		_ = appendAudit(sess.Username, sess.Role, "project.backup", "backup", in.ProjectID, resp.Status, "http", details)
		writeJSON(w, 200, resp)
	})

	protected.HandleFunc("POST /api/v1/actions/backup-now", func(w http.ResponseWriter, r *http.Request) {
		sess, err := sessionFromRequest(r)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
			return
		}
		if sess.Role != "super_admin" {
			_ = appendAudit(sess.Username, sess.Role, "backup.now", "backup", "hosting-control-panel", "denied", "http", map[string]any{})
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}
		_ = appendAudit(sess.Username, sess.Role, "backup.now", "backup", "hosting-control-panel", "started", "http",
			map[string]any{"scope": "control_plane_state"})
		resp, err := submitControlPlaneBackup(sess.Username, sess.Role)
		if err != nil {
			_ = appendAudit(sess.Username, sess.Role, "backup.now", "backup", "hosting-control-panel", "failure", "http",
				map[string]any{"scope": "control_plane_state", "reason": err.Error()})
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "backup action unavailable"})
			return
		}
		details := map[string]any{"request_id": resp.RequestID, "agent_version": resp.AgentVersion, "scope": "control_plane_state"}
		if resp.Result != nil {
			if p, ok := resp.Result["archive_path"]; ok {
				details["archive_path"] = p
			}
			if h, ok := resp.Result["archive_sha256"]; ok {
				details["archive_sha256"] = h
			}
		}
		_ = appendAudit(sess.Username, sess.Role, "backup.now", "backup", "hosting-control-panel", resp.Status, "http", details)
		writeJSON(w, 200, resp)
	})

	protected.HandleFunc("GET /api/v1/backups/contract", func(w http.ResponseWriter, r *http.Request) {
		sess, err := sessionFromRequest(r)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
			return
		}
		if sess.Role != "super_admin" {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}
		v, err := loadBackupContract()
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "backup contract unavailable"})
			return
		}
		writeJSON(w, 200, v)
	})

	protected.HandleFunc("GET /api/v1/backups/preflight", func(w http.ResponseWriter, r *http.Request) {
		sess, err := sessionFromRequest(r)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
			return
		}
		if sess.Role != "super_admin" {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}
		v, err := loadBackupPreflight()
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "backup preflight unavailable"})
			return
		}
		writeJSON(w, 200, v)
	})

	protected.HandleFunc("GET /api/v1/backups/adapters", func(w http.ResponseWriter, r *http.Request) {
		sess, err := sessionFromRequest(r)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
			return
		}
		if sess.Role != "super_admin" {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}
		v, err := loadBackupAdapters()
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "backup adapter audit unavailable"})
			return
		}
		writeJSON(w, 200, v)
	})

	protected.HandleFunc("GET /api/v1/backups/history", func(w http.ResponseWriter, r *http.Request) {
		sess, err := sessionFromRequest(r)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
			return
		}
		if sess.Role != "super_admin" {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
			return
		}
		snap, err := loadSnapshot()
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "snapshot unavailable"})
			return
		}
		history := []any{}
		if snap.Backups != nil {
			if raw, ok := snap.Backups["control_plane_history"]; ok {
				if list, ok := raw.([]any); ok {
					history = list
				}
			}
		}
		writeJSON(w, 200, map[string]any{
			"scope": "control_plane_state",
			"count": len(history),
			"items": history,
		})
	})

	protected.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		s, err := loadSnapshot()
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "snapshot unavailable"})
			return
		}
		writeJSON(w, 200, map[string]any{"schema_version": s.SchemaVersion, "generated_at": s.GeneratedAt, "mode": "authenticated_control_plane", "contract": "hosting-panel-snapshot/5.0", "panel_version": "v0.20.1"})
	})
	protected.HandleFunc("GET /api/v1/snapshot", func(w http.ResponseWriter, r *http.Request) {
		s, err := loadSnapshot()
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "snapshot unavailable"})
			return
		}
		sess, _ := sessionFromRequest(r)
		s, err = filteredSnapshot(s, sess)
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "rbac filtering unavailable"})
			return
		}
		writeJSON(w, 200, s)
	})
	protected.HandleFunc("GET /api/v1/rbac/meta", func(w http.ResponseWriter, r *http.Request) {
		v, err := rbacMeta()
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "rbac unavailable"})
			return
		}
		writeJSON(w, 200, v)
	})
	protected.HandleFunc("GET /api/v1/rbac/users", func(w http.ResponseWriter, r *http.Request) {
		users, err := listUsers()
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "rbac unavailable"})
			return
		}
		writeJSON(w, 200, map[string]any{"users": users})
	})
	protected.HandleFunc("GET /api/v1/audit/meta", func(w http.ResponseWriter, r *http.Request) {
		v, err := auditMeta()
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "audit unavailable"})
			return
		}
		writeJSON(w, 200, v)
	})
	protected.HandleFunc("GET /api/v1/audit", func(w http.ResponseWriter, r *http.Request) {
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		events, err := listAudit(limit)
		if err != nil {
			writeJSON(w, 503, map[string]string{"error": "audit unavailable"})
			return
		}
		writeJSON(w, 200, map[string]any{"mode": "read-only", "events": events})
	})
	protected.Handle("/", webServer)

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/healthz",
			r.URL.Path == "/login",
			r.URL.Path == "/styles.css",
			r.URL.Path == "/login.js",
			r.URL.Path == "/api/v1/auth/status",
			r.URL.Path == "/api/v1/auth/login":
			public.ServeHTTP(w, r)
		default:
			// RBAC administration and global audit are Super Admin only.
			if strings.HasPrefix(r.URL.Path, "/api/v1/rbac/") || strings.HasPrefix(r.URL.Path, "/api/v1/audit") {
				requireSession(requireRole("super_admin")(protected)).ServeHTTP(w, r)
				return
			}
			requireSession(protected).ServeHTTP(w, r)
		}
	})

	srv := &http.Server{
		Addr: ":8080", Handler: securityHeaders(handler),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
	}
	log.Println("hosting-control-panel v0.20.1 ui-polish listening on :8080")
	log.Fatal(srv.ListenAndServe())
}
