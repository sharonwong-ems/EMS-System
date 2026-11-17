// Shared code for every page. Load order on each page:
// supabase-js CDN -> config.js -> app.js -> page script.

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const ROLE_LABEL = { owner: 'Owner 老板', manager: 'Manager 经理', staff: 'Staff 员工' };
const STATUS_LABEL = {
  pending: 'Waiting approval 待批准',
  approved: 'Approved, not paid 已批准（未付款）',
  paid: 'Paid 已付款',
  cancelled: 'Cancelled 已取消'
};

// ---------- formatting ----------
function fmtRM(n) {
  const v = Number(n || 0);
  return 'RM ' + v.toLocaleString('en-MY', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// '2026-11-17' or a timestamp -> '17 Nov 2026'
function fmtDate(d) {
  if (!d) return '';
  let dt;
  if (typeof d === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(d)) {
    const [y, m, day] = d.split('-').map(Number);
    dt = new Date(y, m - 1, day);
  } else {
    dt = new Date(d);
  }
  return dt.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

// Today as 'YYYY-MM-DD' in local time
function todayISO() {
  const t = new Date();
  return t.getFullYear() + '-' + String(t.getMonth() + 1).padStart(2, '0') + '-' + String(t.getDate()).padStart(2, '0');
}

// Whole days from an ISO date ('YYYY-MM-DD') until today
function daysSince(isoDate) {
  const [y, m, d] = isoDate.split('-').map(Number);
  const then = new Date(y, m - 1, d);
  const now = new Date(); now.setHours(0, 0, 0, 0);
  return Math.round((now - then) / 86400000);
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ---------- friendly errors ----------
function friendlyError(err) {
  const m = (err && (err.message || err.error_description || String(err))) || '';
  if (/Invalid login credentials/i.test(m)) return 'Wrong email or password. Please try again.';
  if (/Email not confirmed/i.test(m)) return 'Please open the email we sent you and click the link first.';
  if (/User already registered/i.test(m)) return 'This email already has an account. Please sign in instead.';
  if (/Password should be at least/i.test(m)) return 'Password must be at least 6 characters.';
  if (/rate limit/i.test(m)) return 'Too many tries. Please wait a few minutes and try again.';
  if (/Failed to fetch|NetworkError/i.test(m)) return 'Cannot connect. Please check your internet and try again.';
  if (/row-level security|permission denied/i.test(m)) return 'Sorry, you are not allowed to do this.';
  if (/relation .* does not exist|Could not find the table/i.test(m)) return 'The database is not set up yet. Please run schema.sql in Supabase.';
  // Messages written by our own database rules are already friendly
  if (m && m.length < 200) return m;
  return 'Something went wrong. Please try again.';
}

function showMsg(el, text, type) {
  el.textContent = text;
  el.className = 'msg ' + (type || 'error');
  el.classList.remove('hidden');
}

// ---------- login & roles ----------
async function getProfile() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return null;
  const { data, error } = await sb.from('profiles').select('*').eq('id', session.user.id).maybeSingle();
  if (error) throw error;
  return data;
}

// Call at the top of every page except index.html.
// Sends people who are not logged in, switched off, or not allowed back to index.html.
async function requireRole(allowed) {
  let profile = null;
  try { profile = await getProfile(); } catch (e) { /* fall through */ }
  if (!profile || !profile.active || (allowed && !allowed.includes(profile.role))) {
    location.href = 'index.html';
    return null;
  }
  return profile;
}

async function signOut() {
  await sb.auth.signOut();
  location.href = 'index.html';
}

// ---------- settings (rule numbers) ----------
async function getSettings() {
  const { data, error } = await sb.from('settings').select('key,value');
  if (error) throw error;
  const s = {};
  (data || []).forEach(r => { s[r.key] = r.value; });
  return {
    overdueDays: Number(s.overdue_days),
    lowStockBags: Number(s.low_stock_bags),
    recentAlertDays: Number(s.recent_alert_days),
    supplierName: s.supplier_name || '',
    supplierWhatsapp: (s.supplier_whatsapp || '').replace(/\D/g, '')
  };
}

// WhatsApp link with the message already typed; a person presses Send.
function waLink(phone, text) {
  return 'https://wa.me/' + encodeURIComponent(phone) + '?text=' + encodeURIComponent(text);
}

// ---------- alerts (per role) ----------
// Returns a list of { text, level: 'info'|'warn'|'danger'|'ok', link?, linkText?, wa? }
async function loadAlerts(profile) {
  const st = await getSettings();
  const alerts = [];
  const role = profile.role;
  const isBoss = role === 'manager' || role === 'owner';

  // Overdue: approved, not paid, more than overdue_days since order date
  const cutoff = new Date(); cutoff.setHours(0, 0, 0, 0); cutoff.setDate(cutoff.getDate() - st.overdueDays);
  const cutoffISO = cutoff.getFullYear() + '-' + String(cutoff.getMonth() + 1).padStart(2, '0') + '-' + String(cutoff.getDate()).padStart(2, '0');
  const { data: overdue, error: e1 } = await sb.from('orders')
    .select('id').eq('status', 'approved').lt('order_date', cutoffISO);
  if (e1) throw e1;

  if (isBoss) {
    if (role === 'manager') {
      const { count, error } = await sb.from('orders').select('id', { count: 'exact', head: true }).eq('status', 'pending');
      if (error) throw error;
      if (count > 0) alerts.push({
        level: 'info', text: `${count} order(s) waiting for your approval.`,
        link: 'orders.html?status=pending', linkText: 'Approve'
      });
    }

    const { data: low, error: e2 } = await sb.from('products')
      .select('name,stock_bags').eq('active', true).lt('stock_bags', st.lowStockBags).order('stock_bags');
    if (e2) throw e2;
    (low || []).forEach(p => {
      const msg = `Hi ${st.supplierName}, we would like to order more ${p.name}. Our stock is now ${p.stock_bags} bags.`;
      alerts.push({
        level: 'warn',
        text: `Low stock: ${p.name} has only ${p.stock_bags} bags (below ${st.lowStockBags}).`,
        wa: st.supplierWhatsapp ? waLink(st.supplierWhatsapp, msg) : null
      });
    });

    if ((overdue || []).length > 0) alerts.push({
      level: 'danger', text: `${overdue.length} order(s) not paid for more than ${st.overdueDays} days.`,
      link: 'orders.html?filter=overdue', linkText: 'See list'
    });
  } else {
    // Staff: their own orders (RLS only returns their own rows)
    if ((overdue || []).length > 0) alerts.push({
      level: 'danger', text: `${overdue.length} of your order(s) not paid for more than ${st.overdueDays} days. Please follow up with the customer.`,
      link: 'orders.html?filter=overdue', linkText: 'See list'
    });
    const since = new Date(Date.now() - st.recentAlertDays * 86400000).toISOString();
    const { data: approved, error: e3 } = await sb.from('orders')
      .select('customer_name,amount,approved_at').eq('status', 'approved').gte('approved_at', since).order('approved_at', { ascending: false });
    if (e3) throw e3;
    (approved || []).forEach(o => alerts.push({
      level: 'ok', text: `Approved: ${o.customer_name}, ${fmtRM(o.amount)} (${fmtDate(o.approved_at)}).`
    }));
    const { data: cancelled, error: e4 } = await sb.from('orders')
      .select('customer_name,amount,cancelled_at').eq('status', 'cancelled').gte('cancelled_at', since).order('cancelled_at', { ascending: false });
    if (e4) throw e4;
    (cancelled || []).forEach(o => alerts.push({
      level: 'warn', text: `Cancelled: ${o.customer_name}, ${fmtRM(o.amount)} (${fmtDate(o.cancelled_at)}).`
    }));
  }
  return alerts;
}

function renderAlerts(listEl, alerts) {
  if (!alerts.length) {
    listEl.innerHTML = '<li class="ok">All good. Nothing needs your attention right now.</li>';
    return;
  }
  listEl.innerHTML = alerts.map(a => `
    <li class="${a.level}">
      <span>${esc(a.text)}</span>
      <span class="actions">
        ${a.link ? `<a class="btn small secondary" href="${esc(a.link)}">${esc(a.linkText)}</a>` : ''}
        ${a.wa ? `<a class="btn small" href="${esc(a.wa)}" target="_blank" rel="noopener">WhatsApp supplier</a>` : ''}
      </span>
    </li>`).join('');
}
