const form=document.getElementById('loginForm');
const err=document.getElementById('loginError');
form.addEventListener('submit',async e=>{
 e.preventDefault();err.classList.add('hidden');
 const username=document.getElementById('username').value.trim();
 const password=document.getElementById('password').value;
 try{
   const r=await fetch('/api/v1/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username,password})});
   const b=await r.json().catch(()=>({}));
   if(!r.ok){throw new Error(b.error||'فشل تسجيل الدخول')}
   location.href='/';
 }catch(e){err.textContent=e.message;err.classList.remove('hidden')}
});
