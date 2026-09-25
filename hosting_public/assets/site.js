/* ═══════════════════════════════════════════════════════════════════════
   SmartBizz — shared site behaviour
   One file for every page: the reveal/nav chrome, then the trial and
   enquiry forms. A category page sets window.SB_CATEGORY before loading
   this, and the trial form opens already set to that business type.
   ═════════════════════════════════════════════════════════════════════ */
(function(){
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Scroll reveals: transform-only, elements are legible before they animate.
  if (!reduce && 'IntersectionObserver' in window) {
    const io = new IntersectionObserver((es)=>{ for (const e of es) if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }, {threshold:.15, rootMargin:'0px 0px -6% 0px'});
    document.querySelectorAll('.rv').forEach(el=>io.observe(el));
  } else {
    document.querySelectorAll('.rv').forEach(el=>el.classList.add('in'));
  }

  // Role cards: tap toggles the flip on touch devices; hover handles desktop.
  document.querySelectorAll('.flip').forEach(c=>{
    c.addEventListener('click', ()=>c.classList.toggle('on'));
    c.addEventListener('keydown', e=>{ if (e.key==='Enter'||e.key===' ') { e.preventDefault(); c.classList.toggle('on'); } });
  });

  // Hero board leans toward the pointer.
  const board = document.getElementById('board');
  if (board && !reduce && matchMedia('(pointer:fine)').matches) {
    const stage = board.parentElement;
    let raf = 0, tx = -14, ty = 10;
    stage.addEventListener('mousemove', e=>{
      const r = stage.getBoundingClientRect();
      const px = (e.clientX - r.left)/r.width - .5, py = (e.clientY - r.top)/r.height - .5;
      tx = -14 + px*14; ty = 10 - py*10;
      if (!raf) raf = requestAnimationFrame(()=>{ board.style.transform = `rotateX(${ty}deg) rotateY(${tx}deg) rotateZ(1deg)`; raf = 0; });
    });
    stage.addEventListener('mouseleave', ()=>{ board.style.transform = ''; });
  }

  // Capability tabs. Keyboard-navigable, and the panels are real content
  // rather than something a screen reader has to guess at.
  const tabs = Array.from(document.querySelectorAll('.cap-tab'));
  if (tabs.length) {
    const show = (tab) => {
      tabs.forEach(t => {
        const on = t === tab;
        t.setAttribute('aria-selected', on ? 'true' : 'false');
        const panel = document.getElementById(t.getAttribute('aria-controls'));
        if (!panel) return;
        panel.classList.toggle('on', on);
        panel.hidden = !on;
      });
    };
    tabs.forEach((t, i) => {
      t.addEventListener('click', () => show(t));
      t.addEventListener('keydown', e => {
        if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
        e.preventDefault();
        const next = tabs[(i + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length];
        next.focus();
        show(next);
      });
    });
  }
})();

// =========================================================================
//  Modal Management & Lead/Trial Automation
// =========================================================================
const DEFAULT_APPS_SCRIPT_WEBHOOK = 'https://script.google.com/macros/s/AKfycbwqdDoJo7T-EAWDGPlgahiPOgu8V6CqM4QGVoY29JcewEXCd1T4_heLF2ZEWk33aoEedw/exec';
const FIRESTORE_BASE = 'https://firestore.googleapis.com/v1/projects/smartdine-restaurant-pos/databases/(default)/documents';

function openTrialModal(presetCategory) {
  // A category page opens the form already set to its own business type, so
  // the visitor never re-answers a question the page they are on implies.
  const sel = document.getElementById('trial_businessCategory');
  const want = presetCategory || window.SB_CATEGORY || '';
  if (sel && want) {
    const hit = Array.from(sel.options).find(o => o.value === want);
    if (hit) sel.value = want;
  }
  document.getElementById('trialFormContainer').style.display = 'block';
  document.getElementById('trialSuccessView').style.display = 'none';
  const overlay = document.getElementById('trialModal');
  overlay.style.display = 'flex';
  setTimeout(() => overlay.classList.add('active'), 10);
  document.body.style.overflow = 'hidden';
}

function openContactModal(planName) {
  if (!planName) planName = 'Commercial Plan';
  document.getElementById('contactPlanLabel').textContent = planName;
  document.getElementById('contact_selectedPlan').value = planName;
  document.getElementById('contactFormContainer').style.display = 'block';
  document.getElementById('contactSuccessView').style.display = 'none';
  const overlay = document.getElementById('contactModal');
  overlay.style.display = 'flex';
  setTimeout(() => overlay.classList.add('active'), 10);
  document.body.style.overflow = 'hidden';
}

function closeModals() {
  document.querySelectorAll('.modal-overlay').forEach(el => {
    el.classList.remove('active');
    setTimeout(() => el.style.display = 'none', 250);
  });
  document.body.style.overflow = '';
}

// Close on backdrop click or Escape key
document.querySelectorAll('.modal-overlay').forEach(overlay => {
  overlay.addEventListener('click', e => {
    if (e.target === overlay) closeModals();
  });
});
window.addEventListener('keydown', e => {
  if (e.key === 'Escape') closeModals();
});

// ── Submit Free Trial Registration ──────────────────────────────────────────
async function handleTrialSubmit(e) {
  e.preventDefault();
  const btn = document.getElementById('trialSubmitBtn');
  const originalText = btn.innerHTML;
  btn.disabled = true;
  btn.innerHTML = '<span>Registering trial...</span>';

  const clientName = document.getElementById('trial_clientName').value.trim();
  const shopName = document.getElementById('trial_shopName').value.trim();
  const businessCategory = document.getElementById('trial_businessCategory').value;
  const mobile = document.getElementById('trial_mobile').value.trim();
  const email = document.getElementById('trial_email').value.trim().toLowerCase();
  const address = document.getElementById('trial_address').value.trim();
  const referralSource = document.getElementById('trial_referralSource').value;
  const gstNo = document.getElementById('trial_gstNo').value.trim().toUpperCase();

  const nowIso = new Date().toISOString();

  // 1. File the lead first, so the request survives whatever happens next.
  //    It goes in as PROVISIONING, not PENDING: the trial handler marks it
  //    APPROVED with the organisation id when it succeeds, and this page sets
  //    it back to PENDING if it does not -- so the console's Pending list
  //    holds exactly the people who still need a human.
  let leadId = null;
  try {
    const leadRes = await fetch(`${FIRESTORE_BASE}/registration_requests`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        fields: {
          clientName: { stringValue: clientName },
          shopName: { stringValue: shopName },
          businessCategory: { stringValue: businessCategory },
          mobile: { stringValue: mobile },
          email: { stringValue: email },
          address: { stringValue: address },
          referralSource: { stringValue: referralSource },
          gstNo: { stringValue: gstNo },
          planTier: { stringValue: 'FREE_TRIAL_14_DAYS' },
          status: { stringValue: 'PROVISIONING' },
          source: { stringValue: 'WEBSITE_PORTAL' },
          createdAt: { stringValue: nowIso }
        }
      })
    });
    const leadDoc = await leadRes.json();
    if (leadDoc && leadDoc.name) leadId = String(leadDoc.name).split('/').pop();
  } catch(err) {
    console.warn('Firestore write warning:', err);
  }

  // Hand the lead back to a human. Used when provisioning did not happen.
  async function leadBackToPending(reason) {
    if (!leadId) return;
    try {
      await fetch(`${FIRESTORE_BASE}/registration_requests/${leadId}?updateMask.fieldPaths=status&updateMask.fieldPaths=provisionError&updateMask.fieldPaths=updatedAt`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ fields: {
          status: { stringValue: 'PENDING' },
          provisionError: { stringValue: String(reason || '').slice(0, 300) },
          updatedAt: { stringValue: new Date().toISOString() }
        } })
      });
    } catch (e) { console.warn('Lead status update warning:', e); }
  }

  // 2. Provision the trial. The deployed script handles REGISTER_TRIAL: it
  //    creates the organisation, generates a temporary password and emails
  //    the credentials. It is a public action, so no secret is sent from this
  //    page.
  //
  //    Posted as text/plain on purpose. A JSON content type triggers a CORS
  //    preflight, which Apps Script does not answer, so the only way to read
  //    the reply from a browser is to keep the request simple and follow the
  //    redirect Apps Script issues to its own content host.
  let provisioned = null;
  let failure = null;
  try {
    const res = await fetch(DEFAULT_APPS_SCRIPT_WEBHOOK, {
      method: 'POST',
      redirect: 'follow',
      headers: { 'Content-Type': 'text/plain;charset=utf-8' },
      body: JSON.stringify({
        action: 'REGISTER_TRIAL',
        client_name: clientName,
        shop_name: shopName,
        business_category: businessCategory,
        mobile: mobile,
        email: email,
        address: address,
        referral_source: referralSource,
        gst_no: gstNo,
        plan: '14-Day Free Trial',
        request_id: leadId || ''
      })
    });
    const text = await res.text();
    try { provisioned = JSON.parse(text); } catch (_) { provisioned = null; }
    if (provisioned && provisioned.success !== true) {
      failure = provisioned.error_code === 'RATE_LIMITED'
        ? 'We already have a recent trial request from this number. Check your inbox — the details may already be on their way.'
        : provisioned.error_code === 'EMAIL_EXISTS'
          ? 'There is already an account for this e-mail. Open the app and sign in, or use Forgot password.'
          : (provisioned.error || 'The trial could not be created just now.');
    }
  } catch (err) {
    // The lead is already recorded in Firestore above, so the team can still
    // reach this person; only the automatic provisioning was missed.
    console.warn('Trial provisioning warning:', err);
    failure = null;
  }
  if (!(provisioned && provisioned.success === true)) {
    await leadBackToPending(failure || (provisioned ? 'Unreadable reply from the trial handler' : 'Trial handler unreachable'));
  }

  // 3. Transition to the success view, saying what actually happened.
  btn.disabled = false;
  btn.innerHTML = originalText;

  const ring = document.getElementById('trialSuccessRing');
  const title = document.getElementById('trialSuccessTitle');
  const box = document.getElementById('trialSuccessBox');

  if (failure) {
    // A definite refusal from the server. Say so rather than showing a tick.
    ring.textContent = '!';
    title.textContent = 'We could not finish that';
    document.getElementById('trialSuccessMsg').textContent = failure;
    box.innerHTML = '<div><strong>📱 What to do:</strong> message us on WhatsApp below and we will set your trial up by hand, usually the same day.</div>';
  } else if (provisioned && provisioned.success === true) {
    ring.textContent = '✓';
    title.textContent = 'Your trial is ready';
    document.getElementById('trialSuccessMsg').innerHTML =
      `Hello <strong>${clientName}</strong>, the 14-day trial for <strong>${shopName}</strong> is live` +
      (provisioned.org_id ? ` under organisation ID <strong>${provisioned.org_id}</strong>` : '') + '.';
    document.getElementById('trialClientEmailDisp').textContent = email;
    if (provisioned.mailed === false) {
      // The account exists but the credentials e-mail did not go out. Say so,
      // and point at WhatsApp, where the team can resend them.
      box.innerHTML =
        '<div><strong>\u26a0\ufe0f One thing:</strong> your account was created, but the e-mail with your temporary password could not be sent. Message us on WhatsApp below quoting organisation ID <strong>' + (provisioned.org_id || '') + '</strong> and we will send it straight away.</div>';
    }
  } else {
    // Reached the server but could not read the reply, or never reached it.
    // The Firestore lead landed, so this is a real request either way.
    ring.textContent = '✓';
    title.textContent = 'Request received';
    document.getElementById('trialSuccessMsg').innerHTML =
      `Thank you <strong>${clientName}</strong>. Your trial request for <strong>${shopName}</strong> is logged.`;
    // The lead is back with the team as PENDING, so this is now true.
    box.innerHTML =
      '<div><strong>📋 What happens now:</strong> the team sets your trial up by hand and e-mails your credentials to <strong>' + email + '</strong>, usually within a business day.</div>' +
      '<div style="margin-top:4px"><strong>📱 Fastest route:</strong> message us on WhatsApp below and we will do it while you wait.</div>';
  }

  const waMsg = encodeURIComponent(`Hi SmartDine Team, I just registered for a 14-Day Free Trial for my restaurant "${shopName}" (${businessCategory}) in ${address}. My email is ${email}. Please help me get onboarded!`);
  document.getElementById('trialWhatsAppBtn').href = `https://wa.me/917997970420?text=${waMsg}`;

  document.getElementById('trialFormContainer').style.display = 'none';
  document.getElementById('trialSuccessView').style.display = 'block';
}

// ── Submit Commercial Plan Contact Inquiry ──────────────────────────────────
async function handleContactSubmit(e) {
  e.preventDefault();
  const btn = document.getElementById('contactSubmitBtn');
  const originalText = btn.innerHTML;
  btn.disabled = true;
  btn.innerHTML = '<span>Submitting inquiry...</span>';

  const name = document.getElementById('contact_name').value.trim();
  const email = document.getElementById('contact_email').value.trim().toLowerCase();
  const phone = document.getElementById('contact_phone').value.trim();
  const city = document.getElementById('contact_city').value.trim();
  const brandName = document.getElementById('contact_brandName').value.trim();
  const businessModel = document.getElementById('contact_businessModel').value;
  const outletsCount = document.getElementById('contact_outletsCount').value;
  const stationsCount = document.getElementById('contact_stationsCount').value;
  const selectedPlan = document.getElementById('contact_selectedPlan').value;
  const requirements = document.getElementById('contact_requirements').value.trim();

  const nowIso = new Date().toISOString();

  // 1. Direct Firestore REST Save to business_inquiries
  try {
    await fetch(`${FIRESTORE_BASE}/business_inquiries`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        fields: {
          clientName: { stringValue: name },
          email: { stringValue: email },
          phone: { stringValue: phone },
          city: { stringValue: city },
          brandName: { stringValue: brandName },
          businessModel: { stringValue: businessModel },
          outletsCount: { stringValue: outletsCount },
          stationsCount: { stringValue: stationsCount },
          selectedPlan: { stringValue: selectedPlan },
          requirements: { stringValue: requirements },
          status: { stringValue: 'NEW_INQUIRY' },
          createdAt: { stringValue: nowIso }
        }
      })
    });
  } catch(err) {
    console.warn('Firestore inquiry write warning:', err);
  }

  // 2. Best-effort ping to the Apps Script webhook. NOTE: the deployed script
  //    has no handler for this action today, so it sends no e-mail — the
  //    request reaches the team through the Firestore write above, which the
  //    admin console lists under Inquiries & Leads. Do not advertise e-mail
  //    on this page until a handler exists.
  try {
    fetch(DEFAULT_APPS_SCRIPT_WEBHOOK, {
      method: 'POST',
      mode: 'no-cors',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'SUBMIT_INQUIRY',
        name: name,
        email: email,
        phone: phone,
        city: city,
        brand_name: brandName,
        business_model: businessModel,
        outlets_count: outletsCount,
        stations_count: stationsCount,
        selected_plan: selectedPlan,
        requirements: requirements
      })
    });
  } catch(err) {
    console.warn('Apps script inquiry webhook warning:', err);
  }

  // 3. Transition to Success View
  btn.disabled = false;
  btn.innerHTML = originalText;

  document.getElementById('contactSuccessMsg').innerHTML = `Hello <strong>${name}</strong>, thank you for inquiring about <strong>${selectedPlan}</strong> for <strong>${brandName}</strong> (${outletsCount})!`;
  document.getElementById('contactClientEmailDisp').textContent = email;

  const waMsg = encodeURIComponent(`Hi SmartDine Enterprise Sales, I submitted an inquiry for ${brandName} (${outletsCount}, ${selectedPlan}). My contact is ${name}, phone ${phone}, email ${email}. Please share commercial proposal!`);
  document.getElementById('contactWhatsAppBtn').href = `https://wa.me/917997970420?text=${waMsg}`;

  const mailSubject = encodeURIComponent(`SmartDine Commercial Inquiry: ${brandName} (${selectedPlan})`);
  const mailBody = encodeURIComponent(`Hello SmartDine Team,

I have submitted a commercial inquiry:
Name: ${name}
Brand: ${brandName}
Outlets: ${outletsCount}
Plan: ${selectedPlan}
Phone: ${phone}
Email: ${email}
Requirements: ${requirements}

Please share commercial details.`);
  document.getElementById('contactEmailDirectBtn').href = `mailto:smartdine.platform@gmail.com?subject=${mailSubject}&body=${mailBody}`;

  document.getElementById('contactFormContainer').style.display = 'none';
  document.getElementById('contactSuccessView').style.display = 'block';
}
