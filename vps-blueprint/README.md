# VPS Infrastructure Blueprint — قالب إنشاء خادم جديد

> نسخة تأسيسية 2026-11-19 | نطاقها الإعدادات فقط، دون نسخ بيانات أو أسرار أو مواقع الخادم المصدر.

## الهدف
إنشاء VPS جديد مستقل مشابه **وظيفياً** لبيئة التشغيل الحالية: Ubuntu LTS، Docker Engine وCompose، مستخدمون منفصلون لخدمات Rootless Docker، شبكة Proxy مشتركة، Nginx Proxy Manager، Uptime Kuma، وأساس للمراقبة والنسخ الاحتياطي. هذا ليس استنساخاً حرفياً لنظام التشغيل أو للصور والبيانات.

## الملفات
- [VPS-BOOTSTRAP-PROMPT.md](VPS-BOOTSTRAP-PROMPT.md): برومبت تشغيل كامل لنقله إلى أي محادثة أو Codex.
- [CURRENT-VPS-BASELINE.md](CURRENT-VPS-BASELINE.md): الإعدادات التي تحققنا منها، والاختلافات المقصودة.
- [scripts/audit-source.sh](scripts/audit-source.sh): جرد قراءة فقط للبيئة الحالية (لا ترفع مخرجاته الخام إلى مستودع عام).
- [scripts/bootstrap-vps.sh](scripts/bootstrap-vps.sh): تثبيت تأسيسي على خادم جديد فقط؛ المعاينة هي الوضع الافتراضي.
- [scripts/verify-vps.sh](scripts/verify-vps.sh): فحص قبول غير مغير.
- [monitoring/compose.yaml](monitoring/compose.yaml): Proxy + Kuma، دون بيانات.
- [monitoring/.env.example](monitoring/.env.example): قيم صور واضحة للاعتماد.
- [scripts/deploy-monitoring.sh](scripts/deploy-monitoring.sh): نشر اختياري منفصل بعد التحقق.

## قاعدة السلامة
1. لا تشغل أوامر APPLY على الخادم القديم أو على أي خادم فيه خدمات فعلية.
2. استخدم Ubuntu Server **24.04 LTS** جديداً؛ تحقق من دعم الإصدارات في يوم التنفيذ.
3. افحص وصول SSH عبر **مفتاح** واتصال بديل قبل أي تغييرات جدار ناري. هذه الحزمة لا تعدل SSH أو UFW آلياً.
4. لا تنسخ أي ملفات /etc الأصلية دون مراجعة؛ لا تنسخ Volumes أو قواعد بيانات أو توكنات أو بيانات Kuma/NPM.
5. خزّن أسماء النطاقات وDNS وTLS وSMTP وTelegram ونسخ التخزين الخارجي في مدير أسرار خارج Git.
6. راجع حجم الذاكرة وأولوية الاستعادة قبل إطلاق أي خدمة. لا تنشئ خمس محركات Rootless تلقائياً إذا لم تكن هناك حاجة فعلية؛ كل محرك يستهلك ذاكرة.
7. الفرع مخصص للمراجعة. **لا نشر للإنتاج، ولا دمج إلى main تلقائياً.**

## البداية السريعة على الخادم الجديد
احفظ الملفات على جهازك أو استنسخ المستودع في الخادم الجديد بعد مراجعة المحتوى. مثال (غيّر اسم المضيف إلى **الاسم الفعلي** للخادم الجديد):

```bash
bash scripts/bootstrap-vps.sh --plan
sudo bash scripts/bootstrap-vps.sh --apply --phase base --expected-hostname NEW-VPS-HOSTNAME --ack-new-vps
sudo bash scripts/bootstrap-vps.sh --apply --phase docker --expected-hostname NEW-VPS-HOSTNAME --ack-new-vps
sudo bash scripts/bootstrap-vps.sh --apply --phase users --users sitea,siteb --expected-hostname NEW-VPS-HOSTNAME --ack-new-vps
bash scripts/verify-vps.sh
```

لا تضع الحسابات القديمة أو أسماء مشاريعها في `--users` افتراضياً. أنشئ مستخدماً لكل مشروع إنتاجي يحتاج إلى عزل منفصل، بعد تقييم أثر الذاكرة.

## نشر المراقبة — خطوة منفصلة
```bash
cp monitoring/.env.example monitoring/.env
# راجع إصدارات الصور المثبتة (tags/digests) وحدث القيم بعد اعتمادها.
bash scripts/deploy-monitoring.sh --plan
sudo bash scripts/deploy-monitoring.sh --apply --expected-hostname NEW-VPS-HOSTNAME --ack-new-vps
```

ينشر Nginx Proxy Manager على 80 و443، ولوحة إدارته على 127.0.0.1:81، وUptime Kuma على 127.0.0.1:3001. لا ينشئ مستخدماً إدارياً ولا شهادات أو نطاقات أو تنبيهات تلقائياً. يجب تغيير بيانات دخول NPM الافتراضية فور التثبيت إن كانت تنطبق على الإصدار المختار.

## ما ليس آلياً ولماذا؟
- **UFW/SSH:** تغييرها تلقائياً قد يقطع اتصالك.
- **DNS/TLS/NPM hosts:** تعتمد على النطاقات الجديدة.
- **النسخ الاحتياطي:** يحتاج مخزناً خارجياً، مفاتيح ومخطط استعادة منفصلاً؛ لا ننسخ مؤقتات النسخ القديمة أو حساباتها.
- **مراقبة خارجية:** مطلوبة لكي يصل التنبيه إذا تعطل VPS نفسه.
- **حدود CPU/RAM/PIDs:** تضبط لكل مشروع بعد قياس الحمل واختبار بيئة معزولة.
- **نقل البيانات:** خارج النطاق تماماً.

## معايير القبول
Ubuntu LTS مدعوم؛ Docker/Compose يعملان؛ Rootless يستخدم systemd+cgroup v2؛ بيانات Rootless خاصة بكل مستخدم؛ NPM/Kuma بصلاحيات وحجوم مستدامة دون نشر واجهات الإدارة؛ SSH متاح؛ لا أسرار في Git؛ استعادة نسخ احتياطية مجربة قبل استقبال مواقع إنتاجية؛ تنبيه خارجي عملي؛ اختبارات إعادة التشغيل مخططة في نافذة صيانة.

## مصادر رسمية
- https://docs.docker.com/engine/install/ubuntu/
- https://docs.docker.com/engine/security/rootless/
- https://docs.docker.com/engine/security/rootless/tips/
- https://ubuntu.com/server/docs/how-to/software/automatic-updates/
- https://github.com/louislam/uptime-kuma/wiki/Reverse-Proxy
