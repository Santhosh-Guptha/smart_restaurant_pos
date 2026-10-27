(function(){
  var nav=document.getElementById('nav'),btn=document.getElementById('menuBtn');
  if(btn){btn.addEventListener('click',function(){var o=nav.classList.toggle('open');btn.setAttribute('aria-expanded',o);});}
  document.querySelectorAll('#navLinks a').forEach(function(a){a.addEventListener('click',function(){nav.classList.remove('open');});});
  var y=document.getElementById('yr');if(y)y.textContent=new Date().getFullYear();
  var picks=document.querySelectorAll('button.pick[data-trade]');
  function setTrade(t){document.body.setAttribute('data-trade',t);
    picks.forEach(function(p){p.setAttribute('aria-pressed',p.getAttribute('data-trade')===t);});
    try{localStorage.setItem('sb-trade',t);}catch(e){}}
  if(picks.length){
    picks.forEach(function(p){p.addEventListener('click',function(){setTrade(p.getAttribute('data-trade'));});});
    var want=null;try{want=(new URLSearchParams(location.search).get('trade')||localStorage.getItem('sb-trade'));}catch(e){}
    if(want&&document.querySelector('button.pick[data-trade="'+want+'"]'))setTrade(want);
  }
})();
