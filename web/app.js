let AUTH=null;
async function requireMe(){
 const r=await fetch('/api/v1/auth/me',{cache:'no-store'});
 if(r.status===401){location.href='/login';throw new Error('authentication required')}
 if(!r.ok)throw new Error('auth unavailable');
 AUTH=await r.json();
 $('currentUser').textContent=`${AUTH.username} · ${AUTH.role}`;
 const isSuper=AUTH.role==='super_admin';
 if($('agentArea')) $('agentArea').classList.toggle('hidden',!isSuper);
 if($('auditArea')) $('auditArea').classList.toggle('hidden',!isSuper);
 if($('globalOps')) $('globalOps').classList.toggle('hidden',!isSuper);
}
async function logout(){
 if(!AUTH)return location.href='/login';
 const r=await fetch('/api/v1/auth/logout',{method:'POST',headers:{'X-CSRF-Token':AUTH.csrf_token}});
 if(r.ok)location.href='/login';
}
const $=id=>document.getElementById(id);
let SNAP=null;
let BACKUP_PREFLIGHT=null;
let BACKUP_CONTRACT=null;
let PROJECT_BACKUP_PENDING=null;
let LAST_PROJECT_BACKUP_RESULT=null;
let BACKUP_HISTORY_ITEMS=[];
let BACKUP_HISTORY_EXPANDED=false;
const BACKUP_HISTORY_LIMIT=10;
const esc=v=>String(v??'—').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
const cls=s=>['healthy','running','online','up','active','running_deployed'].includes(String(s).toLowerCase())?'good':['offline','down','unhealthy','exited','missing','inactive','unresolved'].includes(String(s).toLowerCase())?'bad':'warn';
const fmtBytes=n=>{n=Number(n||0);if(!n)return'0 B';const u=['B','KB','MB','GB','TB'];let i=0;while(n>=1024&&i<u.length-1){n/=1024;i++}return`${n.toFixed(i>1?1:0)} ${u[i]}`};
const fmtUptime=s=>{s=Number(s||0);const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600);return`${d}ي ${h}س`};
const deployLabel=s=>({running_deployed:'قيد التشغيل',compose_ready_not_running:'جاهز للنشر وغير مُشغّل',no_compose:'لا يوجد Compose',missing_path:'المسار غير موجود'})[s]||s||'—';

const verificationLabel=s=>({
 created:'تم الإنشاء',
 integrity_verified:'تم التحقق من السلامة',
 restore_verified:'تم اختبار الاستعادة',
 verification_failed:'فشل التحقق',
 no_backup_yet:'لا توجد نسخة بعد',
 created_pending_refresh:'تم الإنشاء · بانتظار تحديث الحالة'
})[s]||s||'غير معروف';
const verificationClass=s=>s==='restore_verified'||s==='integrity_verified'?'good':s==='verification_failed'?'bad':'warn';
const verificationCode=s=>({restore_verified:'RESTORE VERIFIED',integrity_verified:'INTEGRITY VERIFIED',verification_failed:'VERIFICATION FAILED',created:'CREATED',created_pending_refresh:'CREATED',no_backup_yet:'NO BACKUP YET'})[s]||String(s||'UNKNOWN').toUpperCase();
const projectID=p=>p?.id||p?.project_id||'';
const backupEntry=(items,id)=>{const xs=(items||[]).filter(x=>x.project_id===id);return xs.sort((a,b)=>String(b.restore_verified_at||b.integrity_verified_at||b.created_at||b.modified_at||b.filename||'').localeCompare(String(a.restore_verified_at||a.integrity_verified_at||a.created_at||a.modified_at||a.filename||'')))[0]||null};
const backupSpec=(doc,id)=>((doc&&doc.projects)||[]).find(x=>x.project_id===id)||null;

function renderProjectBackupVerification(b){
 const out=$('projectBackupVerification');if(!out)return;
 const items=b.project_backup_history||[];
 const projects=(SNAP&&SNAP.projects)||[];
 if(!projects.length){out.innerHTML='<div class="muted">لا توجد مشاريع مسجلة.</div>';return}
 out.innerHTML=projects.map(p=>{
   const id=projectID(p),x=backupEntry(items,id);
   let state=x?.verification_state||'no_backup_yet';
   let when=x?.restore_verified_at||x?.integrity_verified_at||x?.created_at||x?.modified_at||'';
   let engine=x?.engine||backupSpec(BACKUP_PREFLIGHT,id)?.engine||'—';
   let detail=x?`${x.filename||''} · ${fmtBytes(x.size_bytes||0)}`:'لم تُنشأ نسخة مشروع بعد';
   if(LAST_PROJECT_BACKUP_RESULT&&LAST_PROJECT_BACKUP_RESULT.project_id===id){
     state='created_pending_refresh';
     engine=LAST_PROJECT_BACKUP_RESULT.engine||engine;
     detail=LAST_PROJECT_BACKUP_RESULT.archive_path||detail;
     when=LAST_PROJECT_BACKUP_RESULT.completed_at||when;
   }
   const readiness=backupSpec(BACKUP_PREFLIGHT,id);
   const extra=!readiness&&id==='institute-ibn-abaas-dashboard'?' · عقد النسخ الحالي يستخدم معرّفًا قديمًا؛ العملية محظورة':(!readiness?'':'');
   return `<div class="row"><span><b>${esc(p.name||id)}</b><br><small><span class="ltr inline-ltr">${esc(id)}</span> · ${esc(engine)} · <span class="ltr inline-ltr">${esc(detail)}</span></small></span><span><b class="${verificationClass(state)}">${esc(verificationLabel(state))}</b><br><small><span class="ltr inline-ltr">${esc(when)}</span>${extra}</small></span></div>`;
 }).join('');
}

function renderProjectBackupOperations(){
 const out=$('projectBackupOperations');if(!out||!SNAP)return;
 const history=(SNAP.backups&&SNAP.backups.project_backup_history)||[];
 const projects=SNAP.projects||[];
 out.classList.add('backup-ops-grid');
 out.innerHTML=projects.map(p=>{
   const id=projectID(p),latest=backupEntry(history,id);
   const pf=backupSpec(BACKUP_PREFLIGHT,id),ct=backupSpec(BACKUP_CONTRACT,id);
   const running=p.status==='online'&&p.deployment_state==='running_deployed';
   const ready=Boolean(AUTH&&AUTH.role==='super_admin'&&running&&pf?.ready_for_backup_implementation&&ct?.ready_for_backup_action_design);
   let reason='جاهز لإنشاء نسخة منطقية لقاعدة البيانات';
   if(!running)reason='المشروع غير مشغّل حاليًا';
   else if(!pf||!ct)reason=id==='institute-ibn-abaas-dashboard'?'معرّف عقد النسخ لا يطابق المعرّف المسجل؛ العملية محظورة':'عقد أو Preflight للنسخ غير متاح';
   else if(!pf.ready_for_backup_implementation||!ct.ready_for_backup_action_design)reason=(pf.blockers||ct.blockers||[]).join(', ')||'المشروع غير جاهز للنسخ';
   const state=LAST_PROJECT_BACKUP_RESULT&&LAST_PROJECT_BACKUP_RESULT.project_id===id?'created_pending_refresh':(latest?.verification_state||'no_backup_yet');
   const availability=ready?'READY':(!running?'OFFLINE / BLOCKED':'BLOCKED');
   return `<article class="backup-op-card">
     <div class="backup-op-head"><div><h4>${esc(p.name||id)}</h4><small class="ltr">${esc(id)}</small></div><span class="state-pill ${verificationClass(state)}">${esc(verificationCode(state))}</span></div>
     <div class="backup-op-facts"><span><small>الحالة</small><b class="${running?'good':'bad'}">${esc(availability)}</b></span><span><small>المحرك</small><b>${esc(pf?.engine||ct?.engine||'—')}</b></span></div>
     <p class="backup-op-reason">${esc(reason)}</p>
     <button type="button" data-project-backup-id="${esc(id)}" ${ready?'':'disabled'}>${ready?'إنشاء Backup':'غير متاح'}</button>
   </article>`;
 }).join('')||'<div class="muted">لا توجد مشاريع مسجلة.</div>';
 out.querySelectorAll('[data-project-backup-id]').forEach(btn=>btn.addEventListener('click',()=>openProjectBackupConfirm(btn.dataset.projectBackupId)));
}

function closeProjectBackupConfirm(){
 PROJECT_BACKUP_PENDING=null;
 $('projectBackupModal')?.classList.add('hidden');
 if($('projectBackupConfirmInput')) $('projectBackupConfirmInput').value='';
 if($('projectBackupConfirmBtn')) $('projectBackupConfirmBtn').disabled=true;
}

function openProjectBackupConfirm(id){
 if(!AUTH||AUTH.role!=='super_admin')return;
 const p=(SNAP?.projects||[]).find(x=>projectID(x)===id);if(!p)return;
 const pf=backupSpec(BACKUP_PREFLIGHT,id),ct=backupSpec(BACKUP_CONTRACT,id);
 const ready=p.status==='online'&&p.deployment_state==='running_deployed'&&pf?.ready_for_backup_implementation&&ct?.ready_for_backup_action_design;
 if(!ready)return;
 PROJECT_BACKUP_PENDING={id,name:p.name||id,engine:pf?.engine||ct?.engine||''};
 $('projectBackupModalTitle').textContent=`تأكيد Backup · ${p.name||id}`;
 $('projectBackupModalText').textContent='سيتم إنشاء نسخة منطقية جديدة لقاعدة بيانات هذا المشروع. لا توجد عملية Restore ولن يتم تعديل قاعدة البيانات.';
 $('projectBackupConfirmID').textContent=id;
 $('projectBackupConfirmInput').value='';
 $('projectBackupConfirmBtn').disabled=true;
 $('projectBackupModal').classList.remove('hidden');
 $('projectBackupConfirmInput').focus();
}

async function executeProjectBackup(){
 if(!AUTH||AUTH.role!=='super_admin'||!PROJECT_BACKUP_PENDING)return;
 const pending={...PROJECT_BACKUP_PENDING},btn=$('projectBackupConfirmBtn'),out=$('projectBackupActionResult');
 if($('projectBackupConfirmInput').value!==pending.id)return;
 btn.disabled=true;btn.textContent='جاري إنشاء النسخة...';out.className='action-result muted';out.textContent=`جاري إنشاء Backup للمشروع ${pending.id}...`;
 try{
   const r=await fetch('/api/v1/actions/project-backup',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':AUTH.csrf_token},body:JSON.stringify({project_id:pending.id,confirm_project_id:pending.id})});
   const b=await r.json().catch(()=>({}));
   if(!r.ok)throw new Error(b.error||b.message||'project backup unavailable');
   if(b.status!=='success')throw new Error(b.message||b.code||'project backup failed');
   const x=b.result||{};
   LAST_PROJECT_BACKUP_RESULT={project_id:pending.id,engine:x.engine||pending.engine,archive_path:x.archive_path||'',archive_sha256:x.archive_sha256||'',completed_at:b.completed_at||''};
   out.className='action-result good';
   out.textContent=`PASS · ${pending.id} · ${x.archive_path||''} · SHA256 ${x.archive_sha256||''} · database_mutation=${x.database_mutation===true?'true':'false'}`;
   closeProjectBackupConfirm();
   await load();
   await loadAudit();
 }catch(e){out.className='action-result bad';out.textContent=`FAIL · ${pending.id} · ${e.message}`}
 finally{btn.textContent='إنشاء النسخة';if(PROJECT_BACKUP_PENDING)btn.disabled=$('projectBackupConfirmInput').value!==PROJECT_BACKUP_PENDING.id}
}

function projectCard(p,i){
 const ssl=p.ssl||{};
 return `<article class="project" data-project="${i}">
   <h3>${esc(p.name)}</h3><div class="subtitle ltr">${esc(p.domain||p.proxy_endpoint)}</div>
   <div class="row"><span>حالة النشر</span><b class="${cls(p.deployment_state)}">${esc(deployLabel(p.deployment_state))}</b></div>
   <div class="row"><span>الخدمة</span><b class="${cls(p.status)}">${esc(p.status)}</b></div>
   <div class="row"><span>Rootless Docker</span><b class="${cls(p.rootless_docker)}">${esc(p.rootless_docker)}</b></div>
   <div class="row"><span>الحاويات</span><b>${(p.containers||[]).length}</b></div>
   <div class="row"><span>SSL</span><b class="${ssl.valid===true?'good':ssl.valid===false?'bad':'warn'}">${ssl.valid===true?`${esc(ssl.days_remaining)} يوم`:ssl.error?esc(ssl.error):'—'}</b></div>
 </article>`;
}

function openProject(i){
 const p=SNAP.projects[i], ssl=p.ssl||{}, cs=p.containers||[];
 $('drawerBody').innerHTML=`
   <div class="detail-title">
     <div class="eyebrow">PROJECT DETAILS</div>
     <h2>${esc(p.name)}</h2>
     <p class="ltr">${esc(p.domain||p.proxy_endpoint)}</p>
   </div>
   <div class="box">
     <div class="row" style="border-top:0"><span>حالة النشر</span><b class="${cls(p.deployment_state)}">${esc(deployLabel(p.deployment_state))}</b></div>
     <div class="row"><span>الحالة</span><b class="${cls(p.status)}">${esc(p.status)}</b></div>
     <div class="row"><span>المستخدم</span><b>${esc(p.owner_resolved||p.owner||'—')}</b></div>
     <div class="row"><span>مصدر المستخدم</span><b>${esc(p.owner_source||'—')}</b></div>
     <div class="row"><span>المسار</span><b class="ltr">${esc(p.path)}</b></div>
     <div class="row"><span>Compose</span><b class="ltr">${esc(p.compose_path||'—')}</b></div>
     <div class="row"><span>Proxy</span><b class="ltr">${esc(p.proxy_endpoint)}</b></div>
     <div class="row"><span>SSL</span><b>${ssl.valid===true?`${esc(ssl.days_remaining)} يوم`:'—'}</b></div>
   </div>
   <div class="detail-section">
     <h3>الحاويات (${cs.length})</h3>
     ${cs.length?cs.map(c=>`<div class="container-card"><div class="name ltr">${esc(c.name)}</div><div class="meta ltr">${esc(c.image)}</div><div class="meta">${esc(c.status)}</div></div>`).join(''):'<div class="box">لا توجد حاويات عاملة حاليًا.</div>'}
   </div>
   <div class="detail-section">
     <h3>حالة التشغيل</h3>
     <div class="box">${esc(p.readiness_message||'—')}</div>
   </div>`;
 $('drawer').classList.remove('hidden');
}

async function loadAudit(){
 if(!AUTH||AUTH.role!=='super_admin')return;
 const r=await fetch('/api/v1/audit?limit=20',{cache:'no-store'});
 if(!r.ok){$('audit').innerHTML='<div class="warn">تعذر قراءة سجل التدقيق</div>';return}
 const a=await r.json(),events=a.events||[];
 $('audit').innerHTML=events.length?events.map(e=>`<div class="row"><span>${esc(new Date(e.occurred_at).toLocaleString('ar'))} · ${esc(e.actor)} · ${esc(e.action)}</span><b class="${e.result==='success'?'good':'warn'}">${esc(e.result)}</b></div>`).join(''):'<div>لا توجد أحداث مسجلة.</div>';
}

async function load(){
 const r=await fetch('/api/v1/snapshot',{cache:'no-store'});if(!r.ok)throw new Error('snapshot unavailable');
 const s=await r.json();SNAP=s;const h=s.host||{};const md=s.metadata||{};$('contractBadge').textContent=`${md.contract_name||'snapshot'} ${md.contract_version||s.schema_version}`;
 $('generated').textContent=`${h.hostname||''} · آخر تحديث ${new Date(s.generated_at).toLocaleString('ar')}`;
 $('hostname').textContent=h.hostname||'—';$('hostStatus').textContent=(h.status||'unknown').toUpperCase();$('hostStatus').className=cls(h.status);
 $('cpu').textContent=`${h.cpu_percent??'—'}%`;$('ram').textContent=`${h.ram_percent??'—'}%`;$('disk').textContent=`${h.disk_percent??'—'}%`;$('diskFree').textContent=`متاح ${fmtBytes(h.disk_free_bytes)}`;
 $('load').textContent=`${h.load_1m??'—'} / ${h.load_5m??'—'} / ${h.load_15m??'—'}`;$('uptime').textContent=fmtUptime(h.uptime_seconds);

 const a=$('alert');if(h.reboot_required){a.classList.remove('hidden');a.textContent='⚠ الخادم يحتاج إعادة تشغيل لتطبيق تحديثات Kernel. لا يتم التنفيذ تلقائيًا.'}else a.classList.add('hidden');

 const di=s.diagnostics||[],db=$('diagnostics');if(di.length){db.classList.remove('hidden');db.innerHTML=di.map(x=>`<div>⚠ ${esc(x.message)}</div>`).join('')}else db.classList.add('hidden');

 $('projects').innerHTML=(s.projects||[]).map(projectCard).join('');
 document.querySelectorAll('[data-project]').forEach(el=>el.addEventListener('click',()=>openProject(Number(el.dataset.project))));

 $('infra').innerHTML=(s.infrastructure||[]).map(c=>`<article class="infra-item"><div class="row" style="border-top:0"><span>${esc(c.name)}</span><b class="${cls(c.state)}">${esc(c.state)}</b></div><div class="row"><span>الصورة</span><b class="ltr">${esc(c.image)}</b></div><div class="row"><span>Health</span><b class="${cls(c.health)}">${esc(c.health||'—')}</b></div></article>`).join('');

 const b=s.backups||{};$('backups').innerHTML=`<div class="row" style="border-top:0"><span>الملفات</span><b>${esc(b.file_count)}</b></div><div class="row"><span>الحجم الإجمالي</span><b>${fmtBytes(b.total_bytes)}</b></div><div class="row"><span>آخر نسخة</span><b>${esc(b.latest_name||'—')}</b></div><div class="row"><span>آخر وقت</span><b>${esc(b.latest_at||'—')}</b></div><div class="backup-list">${(b.recent||[]).map(x=>`<div class="backup-item"><span class="ltr">${esc(x.name)}</span><b>${fmtBytes(x.size_bytes)}</b></div>`).join('')}</div>`;
 renderProjectBackupVerification(b);
 renderProjectBackupOperations();

 const d=(s.storage&&s.storage.root_docker)||s.root_docker||{};$('dockerUsage').innerHTML=`<div class="row" style="border-top:0"><span>Images</span><b>${esc(d.images)}</b></div><div class="row"><span>Reclaimable Images</span><b>${esc(d.images_reclaimable)}</b></div><div class="row"><span>Containers</span><b>${esc(d.containers)}</b></div><div class="row"><span>Volumes</span><b>${esc(d.volumes)}</b></div><div class="row"><span>Build Cache</span><b>${esc(d.build_cache)}</b></div>`;
}
function fail(e){console.error(e);$('generated').textContent='تعذر قراءة Snapshot';}
$('refresh').addEventListener('click',()=>load().catch(fail));
$('drawerClose').addEventListener('click',()=>$('drawer').classList.add('hidden'));
$('drawer').addEventListener('click',e=>{if(e.target.id==='drawer')$('drawer').classList.add('hidden')});
requireMe().then(load).then(loadAudit).then(loadBackupHistory).then(loadBackupAdapters).then(loadBackupPreflight).then(loadBackupContract).catch(fail);

$('logoutBtn').addEventListener('click',logout);

async function agentPing(){
 if(!AUTH||AUTH.role!=='super_admin')return;
 const btn=$('agentPingBtn'),out=$('agentPingResult');
 btn.disabled=true;out.textContent='جاري اختبار الوكيل...';
 try{
   const r=await fetch('/api/v1/actions/ping',{method:'POST',headers:{'X-CSRF-Token':AUTH.csrf_token}});
   const b=await r.json().catch(()=>({}));
   if(!r.ok)throw new Error(b.error||'agent unavailable');
   out.textContent=`PASS · ${b.agent_version} · ${b.request_id} · ${b.message}`;
 }catch(e){out.textContent=`FAIL · ${e.message}`}
 finally{btn.disabled=false}
}

if($('agentPingBtn')) $('agentPingBtn').addEventListener('click',agentPing);

async function backupNow(){
 if(!AUTH||AUTH.role!=='super_admin')return;
 const btn=$('backupNowBtn'),out=$('backupNowResult');
 btn.disabled=true;out.textContent='جاري إنشاء نسخة حالة لوحة التحكم...';
 try{
   const r=await fetch('/api/v1/actions/backup-now',{method:'POST',headers:{'X-CSRF-Token':AUTH.csrf_token}});
   const b=await r.json().catch(()=>({}));
   if(!r.ok)throw new Error(b.error||'backup unavailable');
   const x=b.result||{};
   out.textContent=`PASS · ${x.backup_scope||''} · ${x.archive_path||''} · SHA256 ${x.archive_sha256||''}`;
   await loadBackupHistory();
 }catch(e){out.textContent=`FAIL · ${e.message}`}
 finally{btn.disabled=false}
}
if($('backupNowBtn')) $('backupNowBtn').addEventListener('click',backupNow);


function renderBackupHistory(){
 const out=$('backupHistory');if(!out)return;
 const items=BACKUP_HISTORY_ITEMS||[];
 if(!items.length){out.innerHTML='<div class="muted">لا توجد نسخ مسجلة.</div>';return}
 const visible=BACKUP_HISTORY_EXPANDED?items:items.slice(0,BACKUP_HISTORY_LIMIT);
 const rows=visible.map(x=>`<div class="row"><span><b class="ltr">${esc(x.filename||'')}</b><br><small><span class="ltr inline-ltr">${esc(x.created_at||x.modified_at||'')}</span> · ${Math.max(1,Math.round((x.size_bytes||0)/1024))} KB</small></span><span><b class="${x.integrity==='verified'?'good':'warn'}">${esc(x.integrity||'unknown')}</b><br><small class="ltr">${esc((x.sha256||'').slice(0,16))}…</small></span></div>`).join('');
 const toggle=items.length>BACKUP_HISTORY_LIMIT?`<div class="history-actions"><button type="button" id="backupHistoryToggleBtn">${BACKUP_HISTORY_EXPANDED?'عرض آخر 10 فقط':`عرض المزيد (${items.length-BACKUP_HISTORY_LIMIT})`}</button><span class="muted">المعروض ${visible.length} من ${items.length}</span></div>`:'';
 out.innerHTML=rows+toggle;
 if($('backupHistoryToggleBtn')) $('backupHistoryToggleBtn').addEventListener('click',()=>{BACKUP_HISTORY_EXPANDED=!BACKUP_HISTORY_EXPANDED;renderBackupHistory()});
}

async function loadBackupHistory(){
 if(!AUTH||AUTH.role!=='super_admin')return;
 const out=$('backupHistory');
 try{
   const r=await fetch('/api/v1/backups/history',{cache:'no-store'});
   const b=await r.json().catch(()=>({}));
   if(!r.ok)throw new Error(b.error||'history unavailable');
   BACKUP_HISTORY_ITEMS=b.items||[];
   renderBackupHistory();
 }catch(e){out.textContent=`تعذر تحميل سجل النسخ: ${e.message}`}
}

if($('refreshBackupHistoryBtn')) $('refreshBackupHistoryBtn').addEventListener('click',loadBackupHistory);


async function loadBackupAdapters(){
 if(!AUTH||AUTH.role!=='super_admin')return;
 const out=$('backupAdapters');
 try{
   const r=await fetch('/api/v1/backups/adapters',{cache:'no-store'});
   const b=await r.json().catch(()=>({}));
   if(!r.ok)throw new Error(b.error||'adapter audit unavailable');
   const items=b.projects||[];
   out.innerHTML=items.map(x=>{
     const d=x.database||{},a=x.adapter_recommendation||{};
     return `<div class="row"><span><b>${esc(x.project_id||'')}</b><br><small>${esc(d.engine||'غير مكتشف')} · ${esc(d.container_name||d.service||'')} · ${d.running?'running':'not running'}</small></span><span><b>${esc(x.readiness||'unknown')}</b><br><small>${esc(a.logical_backup||'')} → ${esc(a.restore||'')}</small></span></div>`;
   }).join('')||'<div class="muted">لا توجد بيانات.</div>';
 }catch(e){out.textContent=`تعذر تحميل فحص Backup Adapters: ${e.message}`}
}

if($('refreshBackupAdaptersBtn')) $('refreshBackupAdaptersBtn').addEventListener('click',loadBackupAdapters);


async function loadBackupPreflight(){
 if(!AUTH||AUTH.role!=='super_admin')return;
 const out=$('backupPreflight');
 try{
   const r=await fetch('/api/v1/backups/preflight',{cache:'no-store'});
   const b=await r.json().catch(()=>({}));
   if(!r.ok)throw new Error(b.error||'preflight unavailable');
   BACKUP_PREFLIGHT=b;
   const items=b.projects||[];
   out.innerHTML=items.map(x=>{
     const tools=x.tools||{};
     const versions=Object.entries(tools).map(([k,v])=>`${k}: ${v.available?'✓':'✗'} ${v.version||''}`).join('<br>');
     return `<div class="row"><span><b>${esc(x.project_id||'')}</b><br><small>${esc(x.engine||'unknown')} · ${x.running?'running':'not running'}</small></span><span><b class="${x.ready_for_backup_implementation?'good':'warn'}">${x.ready_for_backup_implementation?'READY':'BLOCKED'}</b><br><small>${versions||esc((x.blockers||[]).join(', '))}</small></span></div>`;
   }).join('')||'<div class="muted">لا توجد بيانات.</div>';
   renderProjectBackupVerification(SNAP?.backups||{});
   renderProjectBackupOperations();
 }catch(e){out.textContent=`تعذر تحميل Backup Preflight: ${e.message}`}
}

if($('refreshBackupPreflightBtn')) $('refreshBackupPreflightBtn').addEventListener('click',loadBackupPreflight);


async function loadBackupContract(){
 if(!AUTH||AUTH.role!=='super_admin')return;
 const out=$('backupContract');
 try{
   const r=await fetch('/api/v1/backups/contract',{cache:'no-store'});
   const b=await r.json().catch(()=>({}));
   if(!r.ok)throw new Error(b.error||'contract unavailable');
   BACKUP_CONTRACT=b;
   const items=b.projects||[];
   out.innerHTML=items.map(x=>{
     const req=x.required_environment||{};
     const reqs=Object.entries(req).map(([k,v])=>`${esc(k)}: ${v.present?'✓':'✗'}`).join(' · ');
     return `<div class="row"><span><b>${esc(x.project_id||'')}</b><br><small>${esc(x.logical_backup||'')} → ${esc(x.restore||'')} · ${esc(x.format||'')}</small></span><span><b class="${x.ready_for_backup_action_design?'good':'warn'}">${x.ready_for_backup_action_design?'READY':'BLOCKED'}</b><br><small>${reqs||esc((x.blockers||[]).join(', '))}</small></span></div>`;
   }).join('')||'<div class="muted">لا توجد بيانات.</div>';
   renderProjectBackupVerification(SNAP?.backups||{});
   renderProjectBackupOperations();
 }catch(e){out.textContent=`تعذر تحميل Backup Contract: ${e.message}`}
}

if($('refreshBackupContractBtn')) $('refreshBackupContractBtn').addEventListener('click',loadBackupContract);

if($('refreshProjectBackupVerificationBtn')) $('refreshProjectBackupVerificationBtn').addEventListener('click',()=>load().catch(fail));


if($('refreshProjectBackupOperationsBtn')) $('refreshProjectBackupOperationsBtn').addEventListener('click',async()=>{await load();await loadBackupPreflight();await loadBackupContract()});
if($('projectBackupCancelBtn')) $('projectBackupCancelBtn').addEventListener('click',closeProjectBackupConfirm);
if($('projectBackupConfirmBtn')) $('projectBackupConfirmBtn').addEventListener('click',executeProjectBackup);
if($('projectBackupConfirmInput')) $('projectBackupConfirmInput').addEventListener('input',()=>{$('projectBackupConfirmBtn').disabled=!PROJECT_BACKUP_PENDING||$('projectBackupConfirmInput').value!==PROJECT_BACKUP_PENDING.id});
if($('projectBackupModal')) $('projectBackupModal').addEventListener('click',e=>{if(e.target.id==='projectBackupModal')closeProjectBackupConfirm()});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!$('projectBackupModal')?.classList.contains('hidden'))closeProjectBackupConfirm()});
