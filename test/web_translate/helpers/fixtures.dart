// Realistic HTML documents for the readability extractor tests.

/// A news article page: site header with navigation, ads, share bars,
/// scripts, a "related stories" rail, comments and a footer.
const newsArticleHtml = r'''
<!DOCTYPE html>
<html lang="en-GB" class="no-js">
<head>
  <meta charset="utf-8">
  <title>Rivers return to the city as old canals reopen | The Daily Ledger</title>
  <meta property="og:title" content="Rivers return to the city as old canals reopen">
  <meta property="og:site_name" content="The Daily Ledger">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="/static/main.css">
  <style>
    body { font-family: Georgia, serif; }
    .ad-slot { min-height: 250px; }
  </style>
  <script>
    window.dataLayer = window.dataLayer || [];
    function gtag(){dataLayer.push(arguments);} gtag('js', new Date());
    if (a < b && c > d) { console.log("</div> is not a tag here"); }
  </script>
  <script type="application/ld+json">{"@type": "NewsArticle", "headline": "Rivers"}</script>
</head>
<body class="article-page">
  <a class="skip-link" href="#content">Skip to content</a>
  <header class="site-header">
    <div class="logo"><a href="/"><img src="/logo.svg" alt="The Daily Ledger"></a></div>
    <nav class="primary-nav">
      <ul>
        <li><a href="/world">World</a></li>
        <li><a href="/business">Business</a></li>
        <li><a href="/science">Science</a></li>
      </ul>
    </nav>
  </header>
  <div class="ad-slot ad-leaderboard" id="ad-top">
    <span class="ad-label">Advertisement</span>
    <iframe src="https://ads.example.com/frame"></iframe>
  </div>
  <div class="layout">
    <div class="content-column">
      <article class="story" itemscope itemtype="https://schema.org/NewsArticle">
        <header class="story-header">
          <p class="kicker">Urban renewal</p>
          <h1 itemprop="headline">Rivers return to the city as old canals reopen</h1>
          <p class="byline">By <a href="/authors/ana">Ana Lima</a> &middot; 12 March 2025</p>
        </header>
        <div class="share-bar">
          <a href="https://twitter.com/share">Share on X</a>
          <a href="https://facebook.com/sharer">Share on Facebook</a>
        </div>
        <figure class="lead-image">
          <img src="/images/canal.jpg" alt="Boats on a reopened canal at sunset" width="1200" height="675">
          <figcaption>The Westgate canal was paved over in 1962.</figcaption>
        </figure>
        <div class="story-body" itemprop="articleBody">
          <p>For more than sixty years, the waterways that once defined the city lay hidden beneath asphalt, car parks and forgotten warehouses.</p>
          <p>This spring, engineers removed the last concrete slab covering the Westgate canal, and water flowed through the old district for the first time since 1962.</p>
          <div class="ad-slot ad-inline"><script>renderAd("inline-1")</script><span>Advertisement</span></div>
          <h2>A slow, expensive revival</h2>
          <p>The project cost &euro;48 million and took seven years, according to the city council, which says the reopened canals will reduce flooding, cool the streets in summer and bring wildlife back to the centre.</p>
          <blockquote><p>&ldquo;We are not building something new. We are giving back what was always there.&rdquo;</p></blockquote>
          <p>Residents were divided at first. Shop owners feared that years of construction would drive customers away, while others worried about rising rents.</p>
          <ul>
            <li>Three kilometres of canal reopened</li>
            <li>Twelve new footbridges</li>
            <li>A 40% drop in reported street flooding</li>
          </ul>
          <aside class="related-inline"><h3>Read more</h3><a href="/other">Other cities pave over rivers</a></aside>
          <p>Similar projects are under way in Seoul, Utrecht and Sheffield, where buried rivers are being &ldquo;daylighted&rdquo; to tackle heat and floods.</p>
        </div>
        <footer class="story-footer"><p>Topics: <a href="/t/cities">Cities</a>, <a href="/t/water">Water</a></p></footer>
      </article>
      <section class="comments" id="comments">
        <h2>Comments (24)</h2>
        <div class="comment"><p>Great news, finally some good planning in this city, I have waited for years.</p></div>
      </section>
    </div>
    <aside class="sidebar">
      <h2>Most read</h2>
      <ol>
        <li><a href="/a">Markets fall as rates rise again across Europe</a></li>
        <li><a href="/b">The best bakeries in the old town, ranked</a></li>
      </ol>
    </aside>
  </div>
  <div class="newsletter-signup"><p>Get the morning briefing in your inbox, every weekday, for free.</p><form><input type="email"><button>Sign up</button></form></div>
  <footer class="site-footer">
    <p>&copy; 2025 The Daily Ledger. All rights reserved.</p>
    <nav><a href="/privacy">Privacy</a> <a href="/terms">Terms</a></nav>
  </footer>
  <noscript><img src="https://tracker.example.com/pixel.gif" width="1" height="1" alt=""></noscript>
  <script src="/static/app.js"></script>
</body>
</html>
''';

/// A personal blog post that uses `<main>` (no `<article>`), with a code
/// sample, an ordered list and an emoji image inline.
const blogWithMainHtml = '''
<!doctype html>
<html lang="de">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title>Sauerteig für Anfänger – Brot &amp; Code</title>
<meta name="application-name" content="Brot &amp; Code">
</head>
<body>
<div id="top-bar"><a href="/">Brot &amp; Code</a> <a href="/archiv">Archiv</a></div>
<main id="main-content">
  <h1>Sauerteig für Anfänger</h1>
  <p class="meta">Veröffentlicht am 3. Mai 2024</p>
  <p>Sauerteig klingt kompliziert, ist aber nur Mehl, Wasser und Geduld.
     In diesem Beitrag zeige ich, wie ich meinen Starter füttere <img class="emoji" src="/e/bread.png" alt="🍞">.</p>
  <h2>Was du brauchst</h2>
  <ol start="1">
    <li>Roggenmehl (Type 1150)</li>
    <li>Lauwarmes Wasser<ul><li>Leitungswasser reicht</li></ul></li>
    <li>Ein Glas mit Deckel</li>
  </ol>
  <h3>Mein Fütterungsplan</h3>
  <p>Ich notiere jede Fütterung in einem kleinen Skript:</p>
  <pre><code>def feed(starter, flour=50, water=50):
    starter.weight += flour + water
    return starter
</code></pre>
  <p>Nach etwa einer Woche riecht der Starter angenehm säuerlich, und er verdoppelt sein Volumen in vier bis sechs Stunden.<br>
  Dann ist er bereit für das erste Brot.</p>
</main>
<div class="footer-links"><a href="/impressum">Impressum</a></div>
</body>
</html>
''';

/// Text full of named and numeric character references.
const entityHeavyHtml = '''
<html><head><title>Caf&eacute; &amp; Cr&egrave;me &#8211; Men&uacute;</title></head>
<body>
<article>
<h1>Caf&eacute; &amp; Cr&egrave;me</h1>
<p>Prices: 3&nbsp;&euro; &ndash; 5&#160;&#8364; &mdash; &frac12; price after 6&nbsp;pm.</p>
<p>&ldquo;Quoted&rdquo; &lsquo;single&rsquo; &laquo;guillemets&raquo; &hellip; &copy; &reg; &trade; &deg;C</p>
<p>Numeric: &#x41;&#66;&#x63; &#128512; &#x1F600; &#150; &#0; &#xD800; &#99999999;</p>
<p>Legacy without semicolon: &copy 2024 &amp more &eacutetude AT&T &unknown; &;</p>
<p>Escaped markup: &lt;b&gt;not bold&lt;/b&gt; and a lone &lt; sign, plus 5 < 6 and 7 > 3.</p>
<p>Greek &alpha;&beta;&gamma; &Omega; math &le; &ge; &ne; &infin; &rarr;</p>
</article>
</body></html>
''';

/// Broken markup: unclosed paragraphs and list items, misnested inline
/// elements, stray end tags, an unclosed `<div>`, attributes without
/// quotes and an unterminated comment at the end.
const malformedHtml = '''
<html>
<head><title>Broken page</title>
<body>
<div class=content id=story>
<h2>Unclosed things
<p>First paragraph has <b>bold <i>and italic</b> text</i> mixed up.
<p>Second paragraph starts without closing the first.
</span></span>
<ul>
<li>Item one
<li>Item two <a href=/x>with link text inside</a> and more words
<li>Item three
</ul>
<table><tr><td>Cell A<td>Cell B<tr><td>Cell C<td>Cell D</table>
<p>Paragraph after list, with a stray end tag here.</div></div>
<p>Text continues after the stray closing tags, still part of the page body and readable.
<p>Last words <span title="a > b">kept</span>.
<!-- an unterminated comment that swallows the rest <p>hidden</p>
''';

/// A latin-1 document; encode with `latin1.encode` to get the bytes.
const latin1Html = '''
<html><head>
<meta charset="iso-8859-1">
<title>Crème brûlée</title>
</head><body>
<article>
<h1>Crème brûlée</h1>
<p>Für vier Personen: Sahne, Eigelb, Zucker und ein wenig Vanille. Ça marche très bien, señor Müller!</p>
<p>Die Masse wird im Wasserbad bei 150 °C etwa 40 Minuten gebacken, danach kühlt sie über Nacht ab.</p>
</article>
</body></html>
''';

/// A windows-1251 (Cyrillic) document declared via http-equiv; encode with
/// [encodeWindows1251].
const cyrillicHtml = '''
<html><head>
<meta http-equiv="Content-Type" content="text/html; charset=windows-1251">
<title>Новости</title>
</head><body>
<article><h1>Новости</h1>
<p>Сегодня в городе открылся новый парк. Жители довольны — «наконец-то!» №1.</p>
<p>Ёлки и ели посажены вдоль всей набережной, и вечером там очень красиво и тихо.</p>
</article>
</body></html>
''';

/// Encodes [text] as windows-1251 (only Cyrillic, ASCII and the few
/// punctuation marks used in [cyrillicHtml]).
List<int> encodeWindows1251(String text) => [
  for (final rune in text.runes)
    switch (rune) {
      < 0x80 => rune,
      >= 0x0410 && <= 0x044F => rune - 0x0410 + 0xC0,
      0x0401 => 0xA8, // Ё
      0x0451 => 0xB8, // ё
      0x2014 => 0x97, // —
      0x00AB => 0xAB, // «
      0x00BB => 0xBB, // »
      0x2116 => 0xB9, // №
      _ => 0x3F, // ?
    },
];

/// A page without semantic containers: the content must be found by text
/// density.
const densityHtml = '''
<html><head><title>How tides work - Ocean Notes</title></head>
<body>
<div id="wrapper">
  <div class="top"><a href="/">Ocean Notes</a> | <a href="/a">About</a> | <a href="/b">Contact</a></div>
  <div class="links">
    <p><a href="/1">Home</a> <a href="/2">Archive</a> <a href="/3">Tags</a> <a href="/4">Random</a></p>
  </div>
  <div class="col">
    <div class="text">
      <h1>How tides work</h1>
      <p>Tides are the rise and fall of sea levels, caused by the combined effects of the gravitational forces exerted by the Moon and the Sun, and the rotation of the Earth.</p>
      <p>Most places in the ocean usually experience two high tides and two low tides each day, a pattern called semi-diurnal, but some locations experience only one high and one low tide a day.</p>
      <p>The times and amplitude of tides at a locale are influenced by the alignment of the Sun and Moon, by the pattern of tides in the deep ocean, and by the shape of the coastline.</p>
    </div>
  </div>
  <div class="links2"><p><a href="/x">Previous post</a> &middot; <a href="/y">Next post</a></p></div>
</div>
</body></html>
''';
