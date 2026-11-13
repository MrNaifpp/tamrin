/* عرض تمرين: مسرح واحد، ولقطات تتوالى على نفس العناصر. */
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const B = document.body;
const icon = id => `<svg><use href="#${id}"/></svg>`;

/* ───── مؤقتات تُلغى عند تغيير اللقطة ───── */
let timers = [];
const later = (ms, fn) => timers.push(setTimeout(fn, ms));
const clearTimers = () => { timers.forEach(clearTimeout); timers = []; };

function tween(from, to, ms, fn) {
  const t0 = performance.now(); let id;
  const tick = t => {
    const p = Math.min(1, (t - t0) / ms), e = 1 - Math.pow(1 - p, 3);
    fn(from + (to - from) * e);
    if (p < 1) id = requestAnimationFrame(tick);
  };
  id = requestAnimationFrame(tick);
  timers.push({ raf: () => cancelAnimationFrame(id) });
}
const _ct = clearTimeout;
window.clearTimeout = x => (x && x.raf ? x.raf() : _ct(x));

/* ───── البيانات ───── */
const SELF = 'راكان التميمي';
const PLAYERS = [ // الاسم، الصف (0 حارس، 1 دفاع، 2 وسط، 3 هجوم)، القوة
  ['يزيد العنزي', 0, 71], ['أنس المالكي', 0, 64],
  ['خالد الشهري', 1, 78], ['عبدالله الحربي', 1, 69], ['بدر الشمري', 1, 62], ['مشعل البقمي', 1, 55],
  ['فهد العتيبي', 2, 84], ['سلطان القحطاني', 2, 76], ['نواف الغامدي', 2, 70], [SELF, 2, 66], ['ريان الزهراني', 2, 58],
  ['ماجد الدوسري', 3, 88], ['تركي المطيري', 3, 73], ['سعود السبيعي', 3, 61],
].map(([name, row, s]) => ({ name, row, s }));
const ROWC = ['var(--gk)', 'var(--def)', 'var(--mid)', 'var(--fwd)'];

const ATTRS = [['pace', 'السرعة'], ['passing', 'التمرير'], ['shooting', 'التسديد'], ['stamina', 'اللياقة'], ['defending', 'الدفاع'], ['awareness', 'الوعي الكروي']];
const DEMO = { pace: 78, passing: 88, shooting: 74, stamina: 81, defending: 62, awareness: 86 };
const WEIGHTS = { // نفس أوزان التطبيق
  'هجوم': { c: 'var(--fwd)', w: [['shooting', 30], ['awareness', 20], ['passing', 15], ['stamina', 15], ['defending', 10], ['pace', 10]] },
  'وسط': { c: 'var(--mid)', w: [['passing', 30], ['awareness', 20], ['shooting', 15], ['stamina', 15], ['defending', 10], ['pace', 10]] },
  'دفاع': { c: 'var(--def)', w: [['defending', 30], ['awareness', 20], ['passing', 15], ['stamina', 15], ['shooting', 10], ['pace', 10]] },
  'حارس': { c: 'var(--gk)', w: [['defending', 35], ['awareness', 25], ['stamina', 15], ['passing', 10], ['pace', 10], ['shooting', 5]] },
};
const attrName = k => ATTRS.find(a => a[0] === k)[1].replace(' الكروي', '');
const overall = (sc, pos) => Math.floor((WEIGHTS[pos].w.reduce((t, [k, w]) => t + sc[k] * w, 0) + 50) / 100);
const bandLabel = v => v >= 90 ? 'استثنائي' : v >= 80 ? 'ممتاز' : v >= 70 ? 'جيد جدًا' : v >= 60 ? 'جيد' : v >= 45 ? 'مقبول' : 'يحتاج تطوير';
const bandTint = v => v >= 85 ? '#30D158' : v >= 70 ? '#9EDBB8' : v >= 50 ? '#FAC29C' : '#D99E8C';

/* لون الرقم: نفس منحدر التطبيق */
function ratingTint(v) {
  const stops = [[0, 0], [50, 20], [70, 58], [85, 124], [95, 140], [100, 146]];
  let h = 146;
  for (let i = 1; i < stops.length; i++) if (v <= stops[i][0]) {
    const [a, ha] = stops[i - 1], [b, hb] = stops[i]; h = ha + (hb - ha) * (v - a) / (b - a); break;
  }
  const d = Math.max(0, Math.min(1, (v - 85) / 10)), s = .72 + .22 * d, br = .98 - .30 * d;
  const l = br * (1 - s / 2), sl = l === 0 || l === 1 ? 0 : (br - l) / Math.min(l, 1 - l);
  return `hsl(${h} ${sl * 100}% ${l * 100}%)`;
}

/* ───── النص ───── */
const capEl = $('#caption'); let capT;
function cap(pos, k, h, p) {
  clearTimeout(capT);
  capEl.classList.add('out');
  capT = setTimeout(() => {
    capEl.className = pos + ' out';
    $('.k', capEl).textContent = k || ''; $('h2', capEl).textContent = h || ''; $('p', capEl).textContent = p || '';
    requestAnimationFrame(() => requestAnimationFrame(() => capEl.classList.remove('out')));
  }, 320);
}

/* ───── الكاميرا ───── */
const unit = () => Math.min(innerHeight, innerWidth * .5625) / 100;
const cam = $('#cam');
function center(el) {
  let x = el.offsetWidth / 2, y = el.offsetHeight / 2;
  for (let n = el; n && n !== cam; n = n.offsetParent) { x += n.offsetLeft; y += n.offsetTop; }
  return [x, y];
}
let lastFocus = ['#page', 1, .5, .5];
function focus(sel, z = 1, tx = .5, ty = .5) {
  lastFocus = [sel, z, tx, ty];
  const W = innerWidth, H = innerHeight, k = unit() / 8.8, s = k * z, [ex, ey] = center($(sel));
  cam.style.transform = `translate(${W * tx - s * ex}px,${H * ty - s * ey}px) scale(${s})`;
}

/* ───── صفحة التمرين ───── */
const rosterEl = $('#roster');
const rowHTML = (name, sub, acc = '') => `<span class="av">${name[0]}</span><span class="t"><b>${name}</b>${sub ? `<span>${sub}</span>` : ''}</span>${acc}`;
function buildPage() {
  [SELF, 'فهد العتيبي', 'ماجد الدوسري', 'خالد الشهري'].forEach((n, i) => {
    const r = document.createElement('div'); r.className = 'row' + (i ? '' : ' off'); r.id = i ? '' : 'selfrow';
    r.innerHTML = rowHTML(n); rosterEl.append(r);
  });
  const sizes = [50, 50, 50, 38, 38, 38, 29, 29, 29], pos = [[50, 44], [22, 56], [77, 58], [36, 12], [64, 14], [50, 88], [8, 22], [93, 24], [24, 92]];
  PLAYERS.filter(p => p.name !== SELF).slice(0, 9).forEach((p, i) => {
    const s = document.createElement('span');
    s.style.cssText = `width:${sizes[i]}px;height:${sizes[i]}px;left:${pos[i][0]}%;top:${pos[i][1]}%;font-size:${sizes[i] * .44}px`;
    s.textContent = p.name[0]; $('#cluster').append(s);
  });
}
function setPage({ reg = false, owes = false, paid = false }) {
  $('#regbtn').classList.toggle('off', reg);
  $('.seat').classList.toggle('off', !reg);
  $('#applepay').classList.toggle('off', !owes);
  $('.paidrow').classList.toggle('off', !paid);
  $('#selfrow').classList.toggle('off', !reg);
  $('#count').textContent = reg ? 10 : 9;
  $('#bar').style.width = (reg ? 10 : 9) / 14 * 100 + '%';
}
function press(el, then) {
  el.classList.add('press');
  later(260, () => { el.classList.remove('press'); then && then(); });
}

/* ───── الضوضاء ───── */
const MSGS = ['مين جاي الثلاثاء؟', 'أنا', '+1', 'أنا ومعي واحد', 'وين الملعب؟', 'الساعة كم؟', 'كم القطة؟', 'كم صرنا؟',
  'أرسل اللوكيشن', 'حوّلت لك', 'مين باقي ما دفع؟', 'اكتمل العدد؟', 'أعتذر يا شباب', 'مين بدالي؟', 'التقسيمة ظالمة 😤', 'نفس الفريق كل مرة',
  'الحساب وش رقمه؟', 'أحد يرد', '👍', '؟؟', 'باقي واحد', 'من الحارس؟', 'أرسلت الإيصال', 'تأكد من التحويل', '9 ولا 10؟', 'صباح الخير',
  'جمعة مباركة', 'وش صار على الملعب؟', 'أنا خارج', 'رجعت', 'حجزتوا؟', 'مين المسؤول؟', '+2', 'الملعب تغيّر', 'بكرة ولا اليوم؟', 'دفعت الأسبوع اللي فات'];
function buildChaos() {
  let seed = 7; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  MSGS.forEach((m, i) => {
    const b = document.createElement('div'); b.className = 'bub' + (rnd() < .22 ? ' me' : '');
    let x, y; do { x = 4 + rnd() * 84; y = 6 + rnd() * 82; } while (Math.abs(x - 46) < 26 && Math.abs(y - 48) < 15);
    const far = i >= 10 ? rnd() : 0;
    b.style.cssText = `left:${x}%;top:${y}%;--s:${i < 10 ? 1 : .7 + far * 1.3};--b:${i < 10 ? 0 : Math.abs(far - .4) * 9}px;--o:${i < 10 ? 1 : .35 + rnd() * .5}`;
    b.textContent = m; $('#chaos').append(b);
  });
}
function chaos(n, stagger) {
  $$('.bub').forEach((b, i) => {
    if (i >= n) return b.classList.remove('in');
    if (b.classList.contains('in')) return;
    later(stagger * (i < 10 ? i : i - 10) + 100, () => b.classList.add('in'));
  });
}

/* ───── المسطرة ───── */
const SP = 16, ticksEl = $('#ticks'), tickEls = [];
let val = 50, step = 0, scores = {};
function buildRuler() {
  for (let v = 0; v <= 100; v++) { const t = document.createElement('i'); t.style.left = v * SP + 'px'; ticksEl.append(t); tickEls.push(t); }
  $('#track').innerHTML = '<i></i>'.repeat(6);
  let drag = null;
  const ruler = $('#ruler');
  ruler.addEventListener('pointerdown', e => { drag = { x: e.clientX, v: val }; ruler.setPointerCapture(e.pointerId); clearTimers(); });
  ruler.addEventListener('pointermove', e => { if (drag) setVal(drag.v - (e.clientX - drag.x) / SP); });
  ruler.addEventListener('pointerup', () => { if (drag) { setVal(Math.round(val)); scores[ATTRS[step][0]] = Math.round(val); drag = null; } });
  ruler.addEventListener('click', e => e.stopPropagation());
}
function setVal(v) {
  val = Math.max(0, Math.min(100, v));
  ticksEl.style.transform = `translateX(${-val * SP}px)`;
  const lo = Math.max(0, Math.floor(val - 60)), hi = Math.min(100, Math.ceil(val + 60));
  for (let i = lo; i <= hi; i++) {
    const prox = Math.max(0, 1 - Math.min(Math.abs(i - val) / 7, 1));
    tickEls[i].style.height = 26 + 46 * Math.pow(prox, .82) + '%';
    tickEls[i].style.opacity = .14 + prox * .5;
  }
  const n = $('#rnum'), r = Math.round(val);
  if (n.textContent != r) n.textContent = r;
  n.style.color = ratingTint(val);
}
function setStep(i, animate = true) {
  step = i;
  $('#rstep').textContent = `${i + 1} من 6`;
  $$('#track i').forEach((t, j) => t.classList.toggle('on', j <= i));
  $('#rlabel').textContent = ATTRS[i][1];
  const target = scores[ATTRS[i][0]] ?? DEMO[ATTRS[i][0]];
  if (animate) { setVal(50); later(250, () => tween(50, target, 1100, setVal)); } else setVal(target);
  scores[ATTRS[i][0]] = target;
}
function buildSummary(sc = DEMO, ovr = overall(sc, 'وسط')) {
  $('#ovr').textContent = ovr; $('#band').textContent = bandLabel(ovr);
  $('#crest').style.background = `linear-gradient(${bandTint(ovr)},color-mix(in srgb,${bandTint(ovr)} 72%,transparent))`;
  $('#grid').innerHTML = ATTRS.map(([k, t]) => `<div class="cell"><div><span>${t}</span><b>${sc[k]}</b></div><u><i style="background:${bandTint(sc[k])}" data-w="${sc[k]}"></i></u></div>`).join('');
  requestAnimationFrame(() => requestAnimationFrame(() => $$('#grid i').forEach(i => i.style.width = i.dataset.w + '%')));
}
const CROWD = [84, 79, 86, 83, 85, 88];
function crowd() {
  const box = $('#crowd'); box.innerHTML = '';
  const mine = overall(DEMO, 'وسط'), all = [mine, ...CROWD], avg = Math.round(all.reduce((a, b) => a + b) / all.length);
  const cr = $('#crest').getBoundingClientRect(), bx = box.getBoundingClientRect();
  const zc = unit() / 9 * 1.3, tx = (cr.left + cr.width / 2 - (bx.left + bx.width / 2)) / zc, ty = (cr.top + cr.height / 2 - (bx.top + bx.height * .38)) / zc;
  CROWD.forEach((v, i) => {
    const c = document.createElement('div'); c.className = 'crest';
    c.style.background = `linear-gradient(${bandTint(v)},color-mix(in srgb,${bandTint(v)} 72%,transparent))`;
    c.innerHTML = `<b>${v}</b>`;
    const a = (i / CROWD.length) * Math.PI * 2 + .5, R = 520;
    const from = `translate(${Math.cos(a) * R}px,${Math.sin(a) * R * .52}px)`;
    c.style.transform = from + ' scale(.4)'; box.append(c);
    later(200 + i * 140, () => { c.style.opacity = 1; c.style.transform = from; });
    later(1900 + i * 160, () => { c.style.transform = `translate(${tx}px,${ty}px) scale(.3)`; c.style.opacity = 0; });
  });
  later(2300, () => tween(mine, avg, 1400, v => { $('#ovr').textContent = Math.round(v); }));
  later(2500, () => { $('#sumnote').textContent = `من ${all.length} تقييمات`; $('#band').textContent = bandLabel(avg); });
}

/* ───── المعادلات ───── */
const FLOAT = ['OVR = ⌊ (Σ wᵢ·xᵢ + 50) / 100 ⌋', 'R = round( avg( OVRᵣ ) )', 'Δ = | Σ A − Σ B |', 'Δ′ = | Δ − 2·(a − b) |', 'Δ ≤ 2', 'score = Σ / max(nₐ, n_b)',
  'Σ wᵢ = 100', 'argmin Δ′', 'a ∈ A, b ∈ B', 'row(a) = row(b)', 'x ∈ [0, 100]', 'w = (30, 20, 15, 15, 10, 10)', 'w_GK = (35, 25, 15, 10, 10, 5)', 'n ≤ 100', 'S₀ = 50',
  'Δ = | Σ A − Σ B |', 'OVR = ⌊ (Σ wᵢ·xᵢ + 50) / 100 ⌋', 'Δ′ < Δ'];
function buildMath() {
  $('#eqs').innerHTML = Object.entries(WEIGHTS).map(([pos, { c, w }], i) =>
    `<div class="eq" style="--c:${c};transition-delay:${i * 160}ms"><span class="pos">${pos}</span><span class="is">=</span>${w.map(([k, n], j) =>
      `<span class="term${j ? '' : ' top'}"><b>${(n / 100).toFixed(2)}</b>${attrName(k)}</span>`).join('<span class="op">+</span>')}</div>`).join('');
  let seed = 3; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  $('#float').innerHTML = FLOAT.map((f, i) => {
    const far = rnd();
    return `<span style="left:${rnd() * 82}%;top:${4 + rnd() * 86}%;font-size:${1.8 + far * 3.4}vh;--o:${.07 + far * .2};--b:${(1 - far) * 3}px;--d:${7 + rnd() * 6}s;--dl:${-rnd() * 12}s">${f}</span>`;
  }).join('');
}

/* ───── التشكيلة: نفس خوارزمية التطبيق ───── */
let teams = [[], []];
const sum = t => t.reduce((a, p) => a + p.s, 0), cnt = (t, r) => t.filter(p => p.row === r).length;
function preferred(row) {
  const [a, b] = teams;
  if (cnt(a, row) !== cnt(b, row)) return cnt(a, row) < cnt(b, row) ? 0 : 1;
  if (a.length !== b.length) return a.length < b.length ? 0 : 1;
  return sum(a) <= sum(b) ? 0 : 1;
}
function bestTrade() {
  const signed = sum(teams[0]) - sum(teams[1]); let best = Math.abs(signed), trade = null;
  if (best <= 2) return null;
  for (const a of teams[0]) for (const b of teams[1]) {
    const g = Math.abs(signed - 2 * (a.s - b.s));
    if (g < best && a.row === b.row) { best = g; trade = [a, b]; }
  }
  return trade;
}
function readout(animate) {
  const a = sum(teams[0]), b = sum(teams[1]), n = Math.max(teams[0].length, teams[1].length, 1);
  const put = (id, v) => { const el = $(id), from = +el.textContent || 0; animate ? tween(from, v, 500, x => el.textContent = Math.round(x)) : el.textContent = v; };
  put('#sa', a); put('#sb', b); put('#gap', Math.abs(a - b));
  $('#gapbox').classList.toggle('ok', Math.abs(a - b) <= 2);
  $('#sc0').textContent = Math.round(a / n); $('#sc1').textContent = Math.round(b / n);
}
function token(p) {
  const el = document.createElement('div'); el.className = 'tok'; el.style.setProperty('--c', ROWC[p.row]);
  const [first, ...rest] = p.name.split(' ');
  el.innerHTML = `<i class="dot"></i><small>${first}</small><b>${rest.join(' ')}</b><em>${p.s}</em>`;
  return p.el = el;
}
function deal(animated) {
  teams = [[], []]; $$('.band').forEach(b => b.innerHTML = ''); readout(false);
  let i = 0;
  for (const row of [0, 1, 2, 3]) for (const p of PLAYERS.filter(p => p.row === row).sort((a, b) => b.s - a.s || a.name.localeCompare(b.name, 'ar'))) {
    const place = () => { const t = preferred(row); teams[t].push(p); $(`.team[data-t="${t}"] .band[data-r="${row}"]`).append(token(p)); readout(animated); };
    animated ? later(500 + i++ * 230, place) : (place(), p.el.style.animation = 'none');
  }
}
function optimise() {
  const trade = bestTrade();
  if (!trade) return later(900, () => { B.classList.add('is-bal'); cap('low', 'التشكيلة', 'والمشرف يعدّل لو حب، ثم ينشر.'); });
  const [a, b] = trade;
  a.el.classList.add('sel'); later(600, () => b.el.classList.add('sel'));
  later(1500, () => {
    const els = [a.el, b.el], before = els.map(e => e.getBoundingClientRect());
    const ph = document.createComment(''); a.el.replaceWith(ph); b.el.replaceWith(a.el); ph.replaceWith(b.el);
    teams[0][teams[0].indexOf(a)] = b; teams[1][teams[1].indexOf(b)] = a;
    els.forEach((e, i) => {
      const r = e.getBoundingClientRect();
      e.style.animation = 'none'; e.style.transition = 'none'; e.style.zIndex = 5;
      const z = unit() / 9 * 1.15; e.style.transform = `translate(${(before[i].left - r.left) / z}px,${(before[i].top - r.top) / z}px) scale(1.12)`;
      e.offsetWidth; e.style.transition = 'transform 1.1s var(--cine)'; e.style.transform = '';
    });
    readout(true);
    later(1300, () => { els.forEach(e => e.classList.remove('sel')); optimise(); });
  });
}

/* ───── الجدار والمشرف والختام ───── */
function buildWall() {
  $('#wallgrid').innerHTML = PLAYERS.map((p, i) => `<div class="row" style="--i:${i}">${rowHTML(p.name, '', `<span class="acc"><svg class="hg"><use href="#i-hourglass"/></svg><svg class="sl"><use href="#i-seal"/></svg></span>`)}</div>`).join('');
}
function notes() {
  const box = $('#notes'); box.innerHTML = ''; const list = [];
  const add = () => {
    const n = document.createElement('div'); n.className = 'note';
    n.innerHTML = `<span class="ic"><img src="assets/icons/glyph.png" alt=""></span><div><b>وصلت قطة بالبطاقة 💳</b><span>لاعب دفع قطة كورة الثلاثاء بالبطاقة وتأكد مقعده تلقائيًا.</span></div>`;
    box.prepend(n); list.unshift(n); n.offsetWidth;
    list.forEach((el, age) => { el.style.zIndex = 20 - age; el.style.opacity = age > 4 ? 0 : 1 - age * .2; el.style.transform = `translateY(${age * 86}px) scale(${1 - age * .03})`; });
  };
  for (let i = 0; i < 7; i++) later(300 + i * 420, add);
  later(300, () => tween(0, 350, 3200, v => $('#money').textContent = Math.round(v / 25) * 25));
  later(3900, () => B.classList.add('is-remind'));
}
const NEXT = ['رجل المباراة', 'بطاقة اللاعب', 'الكرة الطائرة والبادل', 'نسخة الويب', 'English'];

/* ───── اللقطات ───── */
const BEATS = [
  { scene: 'intro', run() { cap('intro', '', 'من القروب إلى الملعب'); chaos(0); } },
  { scene: 'chaos', run() { cap('center', '', 'كل تمرين يبدأ بقروب.'); chaos(10, 170); } },
  { scene: 'chaos', run() { cap('center', '', 'ثم يضيع في القروب.', 'مين جاي؟ وين الملعب؟ مين دفع؟'); chaos(99, 55); } },
  { scene: 'card', run() { cap('bottom', '', 'تمرين يجمعها كلها في مكان واحد.', 'مجموعتك، بعيد عن الواتساب وضوضائه.'); setPage({}); focus('#poster', 1.12, .5, .43); } },
  { scene: 'page', run() { cap('side', 'التمرين القادم', 'متى، وين، ومين جاي. كلها قدامك.'); setPage({}); focus('#page', 1, .36); } },
  { scene: 'page', run() {
      cap('side', 'التسجيل', 'ضغطة واحدة، ومكانك محفوظ.', 'والقائمة تتحدث عند الكل، بدون «أنا» و«+1».'); setPage({}); focus('.cta', 1.5, .36, .45);
      later(1300, () => press($('#regbtn'), () => setPage({ reg: true })));
  } },
  { scene: 'page', cls: 'f-dir', run() { cap('bottom', 'الموقع', 'اسم الملعب هو الزر.'); setPage({ reg: true }); focus('#dir', 2.1, .5, .38); } },
  { scene: 'page', cls: 'f-dir', run() {
      cap('bottom', 'الموقع', 'ويوديك للملعب مباشرة.', 'على هدهد أو خرائط قوقل.'); setPage({ reg: true }); focus('#dir', 2.1, .5, .34);
      $('#mi-hudhud').classList.remove('hot');
      press($('#dir'), () => B.classList.add('is-menu'));
      later(2300, () => $('#mi-hudhud').classList.add('hot'));
      later(2750, () => { B.classList.remove('is-menu'); B.classList.add('is-route'); focus('#dir', 1.5, .72, .38); });
  } },
  { scene: 'rate', run() { cap('low', 'التقييم', 'بعد التمرين، قيّم اللي لعبوا معك.', 'اسحب المسطرة.'); scores = {}; setStep(0); } },
  { scene: 'rate', run() {
      cap('low', 'التقييم', 'ست معايير لكل لاعب.'); scores = {}; setStep(0, false);
      for (let i = 1; i < 6; i++) later(200 + (i - 1) * 1500, () => setStep(i));
      later(200 + 5 * 1500 + 300, () => { B.classList.add('is-sum'); buildSummary(); $('#sumnote').textContent = 'محسوب بأوزان مركز وسط'; $('#rstep').textContent = 'النتيجة'; cap('low', 'التقييم', 'ورقم واحد، محسوب بوزن مركزه.'); });
  } },
  { scene: 'rate', cls: 'is-sum', run() { cap('low', 'التقييم', 'تقييمك مستور، والنتيجة متوسط الكل.', 'رأي واحد مجاملة. رأي المجموعة دقة.'); buildSummary(); $('#rstep').textContent = 'النتيجة'; $$('#track i').forEach(t => t.classList.add('on')); later(700, crowd); } },
  { scene: 'math', run() { cap('bottom', 'خلف الرقم', 'لكل مركز معادلته.', 'المهاجم يُوزن بتسديده، والمدافع بدفاعه، والحارس بوزن يخصه.'); later(350, () => B.classList.add('is-eqs')); } },
  { scene: 'lineup', run() { cap('low', 'التشكيلة', 'تقييم دقيق مع المراكز: فريقان متكافئان.'); deal(true); } },
  { scene: 'lineup', run() { cap('low', 'التشكيلة', 'يبدّل لاعبًا بلاعب حتى يذوب الفرق.'); deal(false); later(900, optimise); } },
  { scene: 'pay', cls: 'f-pay', run() { cap('bottom', 'القطة', 'وبقي آخر شي: الدفع.'); setPage({ reg: true, owes: true }); focus('#applepay', 2.1, .5, .42); } },
  { scene: 'pay', cls: 'f-pay', run() {
      cap('top', 'القطة', 'قطتك وقطة ضيفك، بضغطتين.'); setPage({ reg: true, owes: true }); focus('#applepay', 2.1, .5, .42);
      later(500, () => press($('#applepay'), () => { B.classList.add('is-sheet'); B.classList.remove('f-pay'); focus('#page', 1, .5, .44); }));
      later(1900, () => B.classList.add('is-dbl'));
      later(4700, () => { B.classList.remove('is-dbl'); B.classList.add('is-scan'); $('.f-hint').textContent = 'Face ID'; });
      later(5800, () => { B.classList.add('is-done'); $('.f-hint').textContent = 'دُفعت'; });
      later(7200, () => { B.classList.remove('is-sheet'); setPage({ reg: true, paid: true }); focus('.cta', 1.5, .36, .45); cap('side', 'القطة', 'قطتك وصلت.', 'بدون تحويل، وبدون إيصال.'); });
  } },
  { scene: 'wall', run() { cap('bottom', 'القطة', 'وكل اللاعبين بنفس السهولة.'); buildWall(); $$('#wallgrid .row').forEach((r, i) => later(1100 + i * 150, () => r.classList.add('paid'))); } },
  { scene: 'admin', run() { cap('bottom', 'المشرف', 'والمشرف توصله القطة كاملة.', 'بدون ملاحقة، وبدون «مين باقي ما دفع؟».'); $('#money').textContent = 0; notes(); } },
  { scene: 'outro', run() { cap('bottom', 'والجاي', 'وهذي البداية.'); $('#next').innerHTML = NEXT.map((n, i) => `<span style="--i:${i}">${n}</span>`).join(''); } },
  { scene: 'intro', run() { cap('intro', '', 'تمرينك، مرتّب.'); chaos(0); } },
];

let idx = -1;
function go(i) {
  i = Math.max(0, Math.min(BEATS.length - 1, i));
  if (i === idx) return;
  idx = i; clearTimers();
  const b = BEATS[i];
  B.className = b.cls || ''; B.dataset.scene = b.scene;
  $('.f-hint').textContent = 'أكّد بالزر الجانبي';
  b.run();
  $('#prog').style.width = i / (BEATS.length - 1) * 100 + '%';
  history.replaceState(null, '', '#' + i);
}

/* ───── التشغيل ───── */
function fit() { document.documentElement.style.setProperty('--vh', unit() + 'px'); document.documentElement.style.setProperty('--z', unit() / 9); focus(...lastFocus); }
buildPage(); setPage({}); buildChaos(); buildRuler(); buildMath(); buildWall(); setVal(50); fit();
addEventListener('resize', fit);
addEventListener('keydown', e => {
  if (['ArrowLeft', 'ArrowDown', ' ', 'Enter', 'PageDown'].includes(e.key)) { e.preventDefault(); go(idx + 1); }
  if (['ArrowRight', 'ArrowUp', 'PageUp', 'Backspace'].includes(e.key)) { e.preventDefault(); go(idx - 1); }
  if (e.key === 'Home') go(0);
  if (e.key === 'f') document.documentElement.requestFullscreen?.();
});
addEventListener('click', e => go(idx + (e.clientX > innerWidth * .85 ? -1 : 1)));
let wheelLock = 0;
addEventListener('wheel', e => { const now = Date.now(); if (now < wheelLock || Math.abs(e.deltaY) < 12) return; wheelLock = now + 1100; go(idx + (e.deltaY > 0 ? 1 : -1)); }, { passive: true });
let tsx = null;
addEventListener('touchstart', e => tsx = e.touches[0].clientX, { passive: true });
addEventListener('touchend', e => { if (tsx == null) return; const d = e.changedTouches[0].clientX - tsx; if (Math.abs(d) > 50) go(idx + (d > 0 ? 1 : -1)); tsx = null; }, { passive: true });
document.fonts.ready.then(() => go(+location.hash.slice(1) || 0));
