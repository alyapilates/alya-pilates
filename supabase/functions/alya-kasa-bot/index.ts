// ALYA KASA — Telegram botu (Supabase Edge Function)
// /kasa yazınca menüyle gelir/gider girer; kayıtlar uygulamadaki kasaya (docs: kasa/islemler) yazılır.
//
// Gerekli gizli değerler (Supabase → Edge Functions → Secrets):
//   TELEGRAM_TOKEN   BotFather'ın verdiği token
//   (Webhook gizli anahtarı token'dan otomatik türetilir; kurulum: bu fonksiyonun adresini ?kur=1 ile tarayıcıda aç)
//   ALLOWED_IDS      İzinli Telegram kullanıcı numaraları, virgülle (ör. 123456,789012)
//   TEST_MODE        "0" yapılınca gerçek kasaya yazar; yoksa/başka değerse deneme kasasına (kasa/deneme)
// SUPABASE_URL ve SUPABASE_SERVICE_ROLE_KEY Supabase tarafından otomatik verilir.

const env = (k: string) => (globalThis as any).Deno?.env.get(k) ?? "";
const TG = () => "https://api.telegram.org/bot" + env("TELEGRAM_TOKEN");
const SB = () => env("SUPABASE_URL");
const KEY = () => env("SUPABASE_SERVICE_ROLE_KEY");
const TEST = () => env("TEST_MODE") !== "0"; // güvenli varsayılan: deneme kasası
const KASA = () => (TEST() ? "kasa/deneme" : "kasa/islemler");
const ALLOWED = () => env("ALLOWED_IDS").split(",").map((s) => s.trim()).filter(Boolean);

// ---- uygulamayla aynı kategoriler ----
const CAT: Record<string, [string, string][]> = {
  g: [["cim", "Cimnastik"], ["kick", "Kickboks"], ["pil", "Pilates"], ["ms", "Multisport"], ["digerg", "Diğer"]],
  c: [["maas", "Antrenör Maaş"], ["sigorta", "Sigorta"], ["kira", "Kira"], ["fatura", "Fatura"], ["vergi", "Vergi"], ["taksit", "Taksit Ödemeleri"], ["diger", "Diğer"]],
};
const ODE: [string, string][] = [["havale", "Havale"], ["pos", "Pos"], ["nakit", "Nakit"], ["multi", "Multi"]];
const SPOR = ["cim", "kick", "pil", "ms"];
const AY = ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"];
const catName = (t: string, k: string) => (CAT[t].find((c) => c[0] === k) || [k, k])[1];
const odeName = (k?: string) => (ODE.find((o) => o[0] === k) || ["", ""])[1];
const nrm = (s: unknown) => String(s ?? "").toLocaleLowerCase("tr-TR").normalize("NFC").replace(/\s+/g, " ").trim();
const nf = new Intl.NumberFormat("tr-TR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const money = (n: number) => nf.format(n) + " ₺";
const today = () => new Date(Date.now() + 3 * 3600e3).toISOString().slice(0, 10); // İstanbul
const curYM = () => today().slice(0, 7);
const ayAd = (k: string) => AY[+k.slice(5, 7) - 1];
const lastMonths = () => {
  const [y, m] = curYM().split("-").map(Number);
  return [2, 1, 0].map((d) => { const dt = new Date(Date.UTC(y, m - 1 - d, 1)); return dt.toISOString().slice(0, 7); });
};
export function parseAmt(s: string): number {
  let t = String(s || "").replace(/[^\d.,]/g, "");
  if (!t) return NaN;
  if (t.includes(",")) t = t.replace(/\./g, "").replace(",", ".");
  else if (/^\d{1,3}(\.\d{3})+$/.test(t)) t = t.replace(/\./g, "");
  return Math.round(parseFloat(t) * 100) / 100;
}

// ---- veritabanı (docs tablosu) ----
async function getDoc(path: string): Promise<any> {
  const r = await fetch(SB() + "/rest/v1/docs?select=data&path=eq." + encodeURIComponent(path), {
    headers: { apikey: KEY(), Authorization: "Bearer " + KEY() },
  });
  if (!r.ok) throw new Error("okuma " + r.status);
  const a = await r.json();
  return (a && a[0] && a[0].data) || {};
}
async function merge(path: string, patch: unknown) {
  const r = await fetch(SB() + "/rest/v1/rpc/merge_doc", {
    method: "POST",
    headers: { apikey: KEY(), Authorization: "Bearer " + KEY(), "Content-Type": "application/json" },
    body: JSON.stringify({ p_path: path, p_patch: patch }),
  });
  if (!r.ok) throw new Error("yazma " + r.status + " " + (await r.text()).slice(0, 200));
}
const live = (o: any) => Object.entries(o || {}).filter(([, v]: any) => v && typeof v === "object" && v.x !== 1);

// sporcu / üye listesi (uygulamadaki roster ile aynı mantık)
async function roster(k: string): Promise<{ id: string; ad: string }[]> {
  const out: { id: string; ad: string }[] = [];
  if (k === "cim" || k === "kick") {
    const d = await getDoc("ab/sporcular");
    live(d.m).forEach(([id, v]: any) => {
      const b = nrm(v.br);
      if (k === "cim" ? /cimnastik|jimnastik/.test(b) : /kick|boks/.test(b)) out.push({ id: "ab:" + id, ad: String(v.ad || "") });
    });
  } else if (k === "pil" || k === "ms") {
    const d = await getDoc("cfg/m");
    live(d.m).forEach(([id, v]: any) => { if (k === "ms" && !v.ms) return; out.push({ id: "pl:" + (v.id || id), ad: String(v.name || "") }); });
  }
  return out.filter((p) => p.ad).sort((a, b) => a.ad.localeCompare(b.ad, "tr"));
}

// ---- Telegram ----
async function tg(method: string, body: unknown) {
  const r = await fetch(TG() + "/" + method, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  try { return await r.json(); } catch { return {}; }
}
const kb = (rows: [string, string][][]) => ({ inline_keyboard: rows.map((r) => r.map(([text, data]) => ({ text, callback_data: data }))) });
const chunk = <T>(a: T[], n: number) => a.reduce((o: T[][], x, i) => (i % n ? o[o.length - 1].push(x) : o.push([x]), o), []);

// ---- oturum (kişi başı, tg/oturum dokümanında) ----
type St = {
  chat: number; mid: number; step: string; t?: string; kat?: string; sid?: string; ad?: string;
  ay?: string[]; ode?: string; tutar?: number; acik?: string; cand?: { id: string; ad: string }[]; ask?: number;
};
async function getSt(uid: number): Promise<St | null> {
  const d = await getDoc("tg/oturum");
  const s = d.u && d.u[uid];
  return s && s.x !== 1 ? s : null;
}
const setSt = (uid: number, s: St | null) => merge("tg/oturum", { u: { [uid]: s || { x: 1 } } });

function summary(s: St) {
  const lines = [
    (TEST() ? "🧪 DENEME · " : "") + (s.t === "g" ? "➕ Gelir" : "➖ Gider") + (s.kat ? " · " + catName(s.t!, s.kat) : ""),
  ];
  if (s.ad) lines.push("👤 " + s.ad + (s.ay && s.ay.length ? " · " + s.ay.slice().sort().map(ayAd).join(" + ") + " aidatı" : ""));
  if (s.ode) lines.push("💳 " + odeName(s.ode));
  if (s.tutar) lines.push("💰 " + money(s.tutar));
  if (s.acik && s.acik !== s.ad) lines.push("📝 " + s.acik);
  if (s.t === "g" && s.ode === "pos" && s.sid) lines.push("ℹ️ POS · bakiyeye dahil değil (ay sonu toplamı ayrıca girilir)");
  return lines.join("\n");
}
async function show(s: St, text: string, rows: [string, string][][] | null) {
  const r = await tg("editMessageText", { chat_id: s.chat, message_id: s.mid, text, reply_markup: rows ? kb(rows) : undefined });
  if (!r.ok && !String(r.description || "").includes("not modified")) {
    const n = await tg("sendMessage", { chat_id: s.chat, text, reply_markup: rows ? kb(rows) : undefined });
    if (n.ok) s.mid = n.result.message_id;
  }
}
// yazı isteyen adım: gruplarda gizlilik modunda cevap bota gitsin diye "force_reply"
async function askText(s: St, uid: number, q: string, first?: string) {
  const r = await tg("sendMessage", {
    chat_id: s.chat, text: q,
    reply_markup: { force_reply: true, selective: true, input_field_placeholder: first || "" },
  });
  if (r.ok) s.ask = r.result.message_id;
}

async function stepOde(s: St) {
  s.step = "ode";
  const os = ODE.filter((o) => !(s.t === "c" && o[0] === "multi"));
  await show(s, summary(s) + "\n\nÖdeme tipi?", [os.map((o) => [o[1], "o:" + o[0]] as [string, string]), [["Belirtme", "o:-"], ["✕ İptal", "x"]]]);
}
async function stepAy(s: St) {
  s.step = "ay";
  const ms = Array.from(new Set(lastMonths().concat(s.ay || []))).sort();
  await show(s, summary(s) + "\n\nHangi ay(lar)ın aidatı? (birden fazla seçilebilir)", [
    ms.map((k) => [((s.ay || []).includes(k) ? "✅ " : "") + ayAd(k), "a:" + k] as [string, string]),
    [["Tamam ➜", "a:ok"], ["✕ İptal", "x"]],
  ]);
}
async function confirm(s: St) {
  s.step = "onay";
  await show(s, summary(s) + "\n\nKaydedilsin mi?", [[["✓ Kaydet", "k"], ["✕ İptal", "x"]]]);
}

async function save(s: St, by: string): Promise<string> {
  const id = "tg" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  const now = new Date().toISOString();
  const r: Record<string, unknown> = { t: s.t, tutar: s.tutar, tarih: today(), kat: s.kat, ca: now, ua: now };
  if (s.t === "g" && s.sid && SPOR.includes(s.kat!)) { r.sid = s.sid; r.ay = (s.ay && s.ay.length ? s.ay : [curYM()]).slice().sort(); }
  if (s.ode) r.ode = s.ode;
  const ac = [s.acik || s.ad || "", "Telegram · " + by].filter(Boolean).join(" · ");
  r.acik = ac;
  await merge(KASA(), { i: { [id]: r } });
  return id;
}

// ---- ana akış ----
async function onMessage(m: any) {
  const uid = m.from?.id, chat = m.chat?.id, text = String(m.text || "").trim();
  if (!uid || !chat || !text) return;
  const cmd = text.split(/[\s@]/)[0].toLowerCase();

  if (!ALLOWED().includes(String(uid))) {
    if (cmd.startsWith("/")) await tg("sendMessage", { chat_id: chat, text: "Bu botu kullanma iznin yok.\nTelegram numaran: " + uid + "\n(Yöneticiye bu numarayı ilet.)" });
    return;
  }
  const by = [m.from.first_name, m.from.last_name].filter(Boolean).join(" ") || String(uid);

  // "sil": botun ✓ mesajına cevap
  if (/^sil$/i.test(text) && m.reply_to_message) {
    const reg = await getDoc("tg/kayit");
    const id = reg.m && reg.m[chat + ":" + m.reply_to_message.message_id];
    if (!id || typeof id !== "string") { await tg("sendMessage", { chat_id: chat, text: "Silinecek kayıt bulunamadı. ✓ Kaydedildi mesajına cevap olarak “sil” yaz.", reply_to_message_id: m.message_id }); return; }
    await merge(id.startsWith("D:") ? "kasa/deneme" : "kasa/islemler", { i: { [id.replace(/^D:/, "")]: { x: 1 } } });
    await merge("tg/kayit", { m: { [chat + ":" + m.reply_to_message.message_id]: { x: 1 } } });
    await tg("sendMessage", { chat_id: chat, text: "🗑 Kayıt kasadan silindi.", reply_to_message_id: m.message_id });
    return;
  }

  if (cmd === "/kasa" || cmd === "/start") {
    const r = await tg("sendMessage", { chat_id: chat, text: (TEST() ? "🧪 DENEME MODU\n" : "") + "Ne gireceksin?", reply_markup: kb([[["➕ Gelir", "t:g"], ["➖ Gider", "t:c"]], [["✕ İptal", "x"]]]) });
    if (r.ok) await setSt(uid, { chat, mid: r.result.message_id, step: "t" });
    return;
  }
  if (cmd === "/iptal") { await setSt(uid, null); await tg("sendMessage", { chat_id: chat, text: "İptal edildi." }); return; }

  const s = await getSt(uid);
  if (!s || s.chat !== chat) return;

  if (s.step === "ad") {
    const ros = await roster(s.kat!);
    const q = nrm(text);
    const hit = ros.filter((p) => nrm(p.ad).includes(q) || q.split(" ").every((w) => nrm(p.ad).includes(w))).slice(0, 8);
    if (!hit.length) { await askText(s, uid, "“" + text + "” bulunamadı. Adı tekrar yaz:"); await setSt(uid, s); return; }
    s.cand = hit;
    await show(s, summary(s) + "\n\nSporcuyu seç:", chunk(hit.map((p, i) => [p.ad, "s:" + i] as [string, string]), 2).concat([[["🔎 Tekrar ara", "s:r"], ["Sporcusuz devam", "s:-"]]]));
    await setSt(uid, s);
    return;
  }
  if (s.step === "tutar") {
    const n = parseAmt(text);
    if (!isFinite(n) || n <= 0) { await askText(s, uid, "Tutarı rakamla yaz (ör. 4000 veya 4.000):"); await setSt(uid, s); return; }
    s.tutar = n;
    if (s.sid) await confirm(s);
    else { s.step = "acik"; await askText(s, uid, "Kısa açıklama yaz (ör. market, kira, Ahmet Yılmaz). Yoksa - yaz:"); }
    await setSt(uid, s);
    return;
  }
  if (s.step === "acik") {
    s.acik = text === "-" ? "" : text.slice(0, 200);
    await confirm(s);
    await setSt(uid, s);
    return;
  }
}

async function onCallback(q: any) {
  const uid = q.from?.id, data = String(q.data || ""), msg = q.message;
  const ans = (text?: string, alert = false) => tg("answerCallbackQuery", { callback_query_id: q.id, text, show_alert: alert });
  if (!ALLOWED().includes(String(uid))) { await ans("Bu botu kullanma iznin yok.", true); return; }
  const s = await getSt(uid);
  if (!s || !msg || s.mid !== msg.message_id) { await ans("Bu menü sana ait değil ya da süresi doldu. /kasa yaz.", true); return; }
  if (data === "x") { await setSt(uid, null); await show(s, "✕ İptal edildi.", null); await ans(); return; }
  const [k, v] = [data.slice(0, 1), data.slice(2)];

  if (k === "t" && s.step === "t") {
    s.t = v; s.step = "kat";
    await show(s, summary(s) + "\n\nKategori?", chunk(CAT[v].map((c) => [c[1], "k:" + c[0]] as [string, string]), 3).concat([[["✕ İptal", "x"]]]));
  } else if (k === "k" && s.step === "kat") {
    s.kat = v;
    if (s.t === "g" && SPOR.includes(v)) {
      const ros = await roster(v);
      if (ros.length) { s.step = "ad"; await show(s, summary(s) + "\n\nSporcunun adını yaz (birkaç harf yeter).", [[["Sporcusuz devam", "s:-"], ["✕ İptal", "x"]]]); await askText(s, uid, "Sporcu adı:", "ör. eli"); }
      else await stepOde(s);
    } else await stepOde(s);
  } else if (k === "s" && (s.step === "ad")) {
    if (v === "r") { await askText(s, uid, "Sporcu adı:", "ör. eli"); }
    else if (v === "-") { delete s.sid; delete s.ad; await stepOde(s); }
    else { const p = (s.cand || [])[+v]; if (p) { s.sid = p.id; s.ad = p.ad; s.acik = p.ad; s.ay = [curYM()]; delete s.cand; await stepAy(s); } }
  } else if (k === "a" && s.step === "ay") {
    if (v === "ok") { if (!s.ay || !s.ay.length) { await ans("En az bir ay seç.", true); return; } await stepOde(s); }
    else { const a = s.ay || []; s.ay = a.includes(v) ? a.filter((z) => z !== v) : a.concat(v); await stepAy(s); }
  } else if (k === "o" && s.step === "ode") {
    if (v !== "-") s.ode = v; else delete s.ode;
    s.step = "tutar";
    await show(s, summary(s) + "\n\nTutarı yaz.", [[["✕ İptal", "x"]]]);
    await askText(s, uid, "Tutar (₺):", "ör. 4000");
  } else { await ans(); return; }
  await setSt(uid, s);
  await ans();
}

async function onSave(q: any) {
  const uid = q.from?.id, msg = q.message;
  if (!ALLOWED().includes(String(uid))) { await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Bu botu kullanma iznin yok.", show_alert: true }); return; }
  const s = await getSt(uid);
  if (!s || !msg || s.mid !== msg.message_id || s.step !== "onay") { await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Bu menünün süresi doldu. /kasa yaz.", show_alert: true }); return; }
  const by = [q.from.first_name, q.from.last_name].filter(Boolean).join(" ") || String(uid);
  try {
    const id = await save(s, by);
    await show(s, "✓ Kaydedildi\n" + summary(s) + "\n\nYanlışsa bu mesaja cevap olarak “sil” yaz.", null);
    await merge("tg/kayit", { m: { [s.chat + ":" + s.mid]: (TEST() ? "D:" : "") + id } });
    await setSt(uid, null);
    await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Kaydedildi" });
  } catch (e) {
    await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Kaydedilemedi, tekrar dene.", show_alert: true });
    console.error(e);
  }
}

// Telegram'ın her istekte gönderdiği gizli anahtar: token'dan türetilir (kimse ayrıca girmek zorunda kalmaz)
async function hookSecret(): Promise<string> {
  const t = env("TELEGRAM_TOKEN");
  if (!t) return "";
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("alya-kasa:" + t));
  return Array.from(new Uint8Array(b)).map((x) => x.toString(16).padStart(2, "0")).join("").slice(0, 48);
}
const html = (t: string) => new Response("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><body style='font:18px system-ui;padding:24px'>" + t, { headers: { "Content-Type": "text/html; charset=utf-8" } });

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    // kurulum: tarayıcıda ...alya-kasa-bot?kur=1 açılınca Telegram'ı bu adrese bağlar
    const u = new URL(req.url);
    if (u.searchParams.get("kur") === "1") {
      if (!env("TELEGRAM_TOKEN")) return html("❌ TELEGRAM_TOKEN henüz Supabase Secrets'a eklenmemiş.");
      const self = env("SUPABASE_URL") + "/functions/v1/alya-kasa-bot";
      const r = await tg("setWebhook", { url: self, secret_token: await hookSecret(), allowed_updates: ["message", "callback_query"], drop_pending_updates: true });
      await tg("setMyCommands", { commands: [{ command: "kasa", description: "Kasaya gelir / gider gir" }, { command: "iptal", description: "Yarım kalan girişi iptal et" }] });
      const me = await tg("getMe", {});
      return html(r.ok ? "✅ Bağlandı. Telegram'da <b>@" + ((me.result && me.result.username) || "bot") + "</b> ile sohbeti açıp <b>/kasa</b> yaz." + (TEST() ? "<br><br>🧪 Deneme modunda: kayıtlar gerçek kasaya yazılmaz." : "") : "❌ Bağlanamadı: " + String(r.description || "token hatalı olabilir"));
    }
    return new Response("ok");
  }
  const sec = await hookSecret();
  if (!sec || req.headers.get("x-telegram-bot-api-secret-token") !== sec) return new Response("yetkisiz", { status: 401 });
  let u: any = {};
  try { u = await req.json(); } catch { return new Response("ok"); }
  try {
    if (u.callback_query) { if (u.callback_query.data === "k") await onSave(u.callback_query); else await onCallback(u.callback_query); }
    else if (u.message) await onMessage(u.message);
  } catch (e) { console.error(e); }
  return new Response("ok"); // Telegram'a her zaman 200 dön (tekrar göndermesin)
}

if ((globalThis as any).Deno?.serve) (globalThis as any).Deno.serve(handle);
