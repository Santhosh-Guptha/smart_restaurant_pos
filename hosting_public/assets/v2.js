(function(){
  var reduce=matchMedia('(prefers-reduced-motion: reduce)').matches;
  var nav=document.getElementById('nav'),btn=document.getElementById('menuBtn'),prog=document.getElementById('progress'),mcta=document.getElementById('mcta');
  function onScroll(){var y=scrollY,max=document.documentElement.scrollHeight-innerHeight;nav.classList.toggle('scrolled',y>8);if(prog)prog.style.setProperty('--p',max>0?y/max:0);if(mcta)mcta.classList.toggle('show',y>innerHeight*.9&&y<max-600);}
  addEventListener('scroll',onScroll,{passive:true});onScroll();
  if(btn){btn.addEventListener('click',function(){var o=nav.classList.toggle('open');btn.setAttribute('aria-expanded',o);});}
  document.querySelectorAll('#navLinks a').forEach(function(a){a.addEventListener('click',function(){nav.classList.remove('open');});});
  if(!reduce&&!CSS.supports('animation-timeline: view()')&&'IntersectionObserver' in window){
    var ro=new IntersectionObserver(function(es){es.forEach(function(e){if(e.isIntersecting){e.target.classList.add('in');ro.unobserve(e.target);}});},{rootMargin:'0px 0px -8% 0px'});
    document.querySelectorAll('.reveal').forEach(function(el){ro.observe(el);});
  }else{document.querySelectorAll('.reveal').forEach(function(el){el.classList.add('in');});}
  document.querySelectorAll('.trade').forEach(function(c){c.addEventListener('pointermove',function(e){var r=c.getBoundingClientRect();c.style.setProperty('--mx',(e.clientX-r.left)+'px');c.style.setProperty('--my',(e.clientY-r.top)+'px');});});
  var toc=document.querySelectorAll('.toc a');
  if(toc.length&&'IntersectionObserver' in window){var map={};toc.forEach(function(a){var el=document.getElementById(a.getAttribute('href').slice(1));if(el)map[el.id]=a;});
    var so=new IntersectionObserver(function(es){es.forEach(function(e){if(e.isIntersecting){toc.forEach(function(a){a.classList.remove('on');});map[e.target.id].classList.add('on');}});},{rootMargin:'-20% 0px -70% 0px'});Object.keys(map).forEach(function(id){so.observe(document.getElementById(id));});}
  var y=document.getElementById('yr');if(y)y.textContent=new Date().getFullYear();
})();