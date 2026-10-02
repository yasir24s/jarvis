import Foundation

/// W1 part 2: the reader's extraction pass, run in the page once it has settled. A small
/// Readability-style pass written for JARVIS (no library): on a copy of the body, it drops what
/// is never the article (scripts, styles, forms, navigation, footers, asides, hidden parts, and
/// blocks whose class or id says comments, sidebar, share, cookie and the like), scores each
/// container by the paragraphs under it (one point, a point per 100 characters up to three, a
/// point per comma; the parent gets it all, the grandparent half, the next a sixth), discounts
/// link-heavy ones, and keeps the best. Its text is its blocks (headings, paragraphs, list
/// items, quotes, code, captions, cells) in order, one blank line apart. When that is under 200
/// characters, the rendered page text is used instead. It also returns the title (`og:title`,
/// else `document.title`), the canonical URL (`link[rel=canonical]`, else `og:url`) and the
/// page's own URL. The live page is never changed. Returns a JSON string.
enum ReadabilityScript {
    /// The most characters the script hands back (the reader keeps `WebReading.textLimit`).
    static let returnLimit = 400_000

    static let source = """
    (() => {
      const doc = document;
      const meta = (sel) => { const e = doc.querySelector(sel); return e ? (e.getAttribute('content') || '').trim() : ''; };
      const title = meta('meta[property="og:title"]') || (doc.title || '').trim();
      let canonical = '';
      const link = doc.querySelector('link[rel~="canonical"]');
      if (link && link.href) canonical = link.href;
      if (!canonical) {
        const og = meta('meta[property="og:url"]');
        if (og) { try { canonical = new URL(og, location.href).href; } catch (e) {} }
      }
      const done = (text) => JSON.stringify({ title, canonical, url: location.href, text: text.slice(0, \(returnLimit)) });
      if (!doc.body) return done('');
      const root = doc.body.cloneNode(true);
      root.querySelectorAll('script,style,noscript,template,svg,canvas,iframe,object,embed,form,button,input,select,' +
        'textarea,nav,footer,aside,dialog,[hidden],[aria-hidden="true"],[role="navigation"],[role="banner"],' +
        '[role="contentinfo"],[role="complementary"]').forEach((e) => e.remove());
      const NEG = /comment|footer|sidebar|side-bar|\\bnav|menu|masthead|banner|promo|advert|sponsor|share|social|related|recommend|newsletter|subscribe|cookie|consent|popup|modal|breadcrumb|pagination|widget|outbrain|taboola/i;
      const POS = /article|content|story|post|entry|main|body|text|blog/i;
      root.querySelectorAll('*').forEach((e) => {
        if (e.tagName === 'ARTICLE' || e.tagName === 'MAIN') return;
        const names = (typeof e.className === 'string' ? e.className : '') + ' ' + (e.id || '');
        if (NEG.test(names) && !POS.test(names)) e.remove();
      });
      const flat = (e) => (e.textContent || '').replace(/\\s+/g, ' ').trim();
      const scores = new Map();
      root.querySelectorAll('p,pre,blockquote,li,td').forEach((p) => {
        const t = flat(p);
        if (t.length < 25) return;
        const score = 1 + Math.min(Math.floor(t.length / 100), 3) + (t.split(',').length - 1);
        let parent = p.parentElement, level = 0;
        while (parent && level < 3) {
          const share = level === 0 ? 1 : level === 1 ? 0.5 : 1 / 6;
          scores.set(parent, (scores.get(parent) || 0) + score * share);
          parent = parent.parentElement; level += 1;
        }
      });
      let best = null, bestScore = 0;
      scores.forEach((s, e) => {
        const length = flat(e).length || 1;
        let linked = 0;
        e.querySelectorAll('a').forEach((a) => { linked += flat(a).length; });
        const adjusted = s * (1 - Math.min(linked / length, 1));
        if (adjusted > bestScore) { best = e; bestScore = adjusted; }
      });
      const container = best || root.querySelector('article') || root.querySelector('main,[role="main"]') || root;
      const BLOCKS = 'h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,figcaption,dt,dd,td,th';
      const parts = [];
      container.querySelectorAll(BLOCKS).forEach((e) => {
        const outer = e.parentElement ? e.parentElement.closest(BLOCKS) : null;
        if (outer && container.contains(outer)) return;
        const t = e.tagName === 'PRE' ? (e.textContent || '').trim() : flat(e);
        if (t) parts.push(t);
      });
      let text = parts.join('\\n\\n');
      if (text.length < 200) text = ((doc.body.innerText || '') + '').trim();
      return done(text);
    })();
    """
}
