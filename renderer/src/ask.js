import MarkdownIt from 'markdown-it'
import hljs from 'highlight.js'
import { wrapQuote } from './comments.js'
import math from './math.js'

/* ------------------------------------------------------------------ ask */

// Asking an assistant about what is being read: a card by the passage for a
// quick question, a panel on the right for a longer one and for the list of a
// document's chats, and a mark in the margin beside every passage that has one.
//
// Everything here lives outside #content. The document is rebuilt on every
// render and its selection is what the comment row reads; a chat inside it
// would be selectable as document text, and gone at the next save.
//
// The page draws and Swift asks. Nothing in here knows which assistant is on
// the other end, its address or its key: a question goes out as a message, and
// the answer comes back a piece at a time through `event`.

let deps = null
let config = { enabled: false, assistant: '', available: false, sees: '', showUsage: true }
let chats = []
/// A chat that has no question yet: the card is open on a selection.
let draft = null
let shown = null
let card = null
let panel = null
let layer = null
let listOpen = false
let expanded = new Set()
let usageTip = null
const drafts = new Map()
let renderTimer = 0

const answerMd = new MarkdownIt({
  html: false,
  linkify: true,
  typographer: false,
  highlight(code, lang) {
    if (lang && hljs.getLanguage(lang)) {
      try {
        return `<pre class="hljs"><code>${hljs.highlight(code, { language: lang, ignoreIllegals: true }).value}</code></pre>`
      } catch {
        // Fall through to plain text.
      }
    }
    return ''
  },
})

// Formulas, as the document draws them: a model explaining one answers in one.
answerMd.use(math)

// Nothing an answer says can load anything: the page's policy already refuses
// every address but its own, and an image is a way to send a word of the
// document to a server of the model's choosing. Shown as the link it is.
answerMd.renderer.rules.image = (tokens, index) => {
  const token = tokens[index]
  const src = escapeHtml(token.attrGet('src') ?? '')
  return `<a href="${src}">${escapeHtml(token.content || src)}</a>`
}

const escapeHtml = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

const bridge = (payload) => deps.bridge({ type: 'ask', ...payload })

const newId = () => `c${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`

const all = () => (draft ? [...chats, draft] : chats)
const find = (id) => all().find((chat) => chat.id === id)

const ICON = {
  // Only until Swift sends the real glyph (config.glyph, a mask): a bubble
  // with three dots, its corner open for a sparkle.
  ask: '<path d="M12 5H6.5A3.5 3.5 0 0 0 3 8.5v7A3.5 3.5 0 0 0 6.5 19H8v3l4-3h4.5a3.5 3.5 0 0 0 3.5-3.5V13"/>'
    + '<path d="M8 12h.01M11.5 12h.01M15 12h.01" stroke-width="2.4"/>'
    + '<path fill="currentColor" stroke="none" d="M18 1.5Q18.9 5.1 22.5 6Q18.9 6.9 18 10.5Q17.1 6.9 13.5 6Q17.1 5.1 18 1.5Z"/>',
  close: '<path d="M6 6l12 12M18 6L6 18"/>',
  panel: '<rect x="3" y="4.5" width="18" height="15" rx="3"/><path d="M15 4.5v15"/>',
  up: '<path d="M12 19V5M6 11l6-6 6 6"/>',
  stop: '<rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor" stroke="none"/>',
  chevron: '<path d="M6 9l6 6 6-6"/>',
  doc: '<path d="M6 3h8l4 4v14H6V3z"/><path d="M14 3v4h4"/>',
  book: '<path d="M3 5.5c3-1 6-1 9 1 3-2 6-2 9-1V19c-3-1-6-1-9 1-3-2-6-2-9-1V5.5z"/><path d="M12 6.5V20"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5L21 21"/>',
  outline: '<path d="M5 6h14M8 12h11M11 18h8"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>',
  note: '<path d="M4 5h16v11H9l-5 4V5z"/><path d="M12 7.5v5M9.5 10h5"/>',
  retry: '<path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20 4v5h-5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  trash: '<path d="M4 7h16"/><path d="M9 7V4h6v3"/><path d="M6 7l1 13h10l1-13"/>',
  warning: '<path d="M12 4l9 16H3L12 4z"/><path d="M12 10v4M12 17v.1"/>',
}

const icon = (name, size = 14, width = 1.6) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${width}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON[name]}</svg>`

const iconButton = (name, label, action, extra = '') =>
  `<button type="button" class="ask-icon ${extra}" data-action="${action}" aria-label="${label}" title="${label}">${icon(name)}</button>`

/* ------------------------------------------------------------- numbers */

const tokens = (n) => {
  if (n == null) return '—'
  if (n < 1000) return String(n)
  if (n < 100_000) return `${(n / 1000).toFixed(1).replace(/\.0$/, '')}k`
  if (n < 1_000_000) return `${Math.round(n / 1000)}k`
  return `${(n / 1_000_000).toFixed(1).replace(/\.0$/, '')}M`
}

const whole = (n) => (n == null ? '—' : n.toLocaleString('en-US'))

const seconds = (s) => {
  if (s == null) return null
  if (s < 60) return `${s.toFixed(1)} s`
  return `${Math.floor(s / 60)} min ${Math.round(s % 60)} s`
}

/// Two significant figures under a cent: an answer that cost $0.00025 said
/// "$0.000", which reads as free.
const money = (c) => {
  if (c == null) return null
  if (c === 0) return '$0'
  if (c < 0.01) return `$${Number(c.toPrecision(2))}`
  if (c < 0.1) return `$${c.toFixed(3)}`
  return `$${c.toFixed(2)}`
}

function metaLine(usage) {
  if (!usage) return ''
  const parts = []
  if (usage.input != null) parts.push(`${tokens(usage.input)} in`)
  if (usage.output != null) parts.push(`${tokens(usage.output)} out`)
  const time = seconds(usage.seconds)
  if (time) parts.push(time)
  if (usage.local) parts.push('local')
  else if (usage.cost != null) parts.push(money(usage.cost))
  return parts.join(' · ')
}

function chatTotals(chat) {
  let input = 0
  let output = 0
  let cached = 0
  let cost = null
  let any = false
  let local = false
  for (const turn of chat.turns) {
    const u = turn.usage
    if (!u) continue
    any = true
    input += u.input ?? 0
    output += u.output ?? 0
    cached += u.cachedInput ?? 0
    if (u.cost != null) cost = (cost ?? 0) + u.cost
    local = local || u.local
  }
  return any ? { input, output, cached, cost, local } : null
}

function totalLine(chat) {
  const t = chatTotals(chat)
  if (!t) return ''
  const price = t.local ? 'local' : money(t.cost)
  return `${tokens(t.input + t.output)} tokens${price ? ` · ${price}` : ''}`
}

const ago = (ms) => {
  const minutes = Math.round((Date.now() - ms) / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${hours} h ago`
  const days = Math.round(hours / 24)
  if (days === 1) return 'Yesterday'
  return new Date(ms).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}

/* -------------------------------------------------------------- anchors */

const topLevel = (el) => {
  const root = deps.content()
  let block = el
  while (block && block.parentElement && block.parentElement !== root) {
    if (block.parentElement.classList.contains('note-holder')) break
    block = block.parentElement
  }
  return block
}

/// The element a chat's passage is in: the block its lines point at if the
/// words are still there, otherwise the nearest block that has them. Lines move
/// whenever anything is written above; the words are what the reader asked
/// about.
/// A selection over several paragraphs cannot be wrapped as one: it is found,
/// and marked, by its first line.
const needleOf = (chat) => (chat.quote.split('\n').find((line) => line.trim()) ?? '').trim()

function blockFor(chat) {
  if (!chat.quote) return null
  const needle = needleOf(chat)
  if (!needle) return null
  const blocks = [...deps.content().querySelectorAll('[data-line]')]
  const has = (el) => el.textContent.includes(needle)
  const exact = blocks.find((el) => deps.lineRange(el)?.start === chat.line && has(el))
  if (exact) return exact
  let best = null
  let distance = Infinity
  for (const el of blocks) {
    if (!has(el)) continue
    const range = deps.lineRange(el)
    const d = Math.abs((range?.start ?? 0) - (chat.line ?? 0))
    // The tighter of two blocks at the same distance: the list item, not the list.
    if (d < distance || (d === distance && best?.contains(el))) {
      best = el
      distance = d
    }
  }
  return best
}

function unwrapAnchors() {
  for (const span of document.querySelectorAll('.ask-anchor')) {
    const parent = span.parentNode
    while (span.firstChild) parent.insertBefore(span.firstChild, span)
    parent.removeChild(span)
    parent.normalize()
  }
}

function wrap(chat) {
  const block = blockFor(chat)
  if (!block) return null
  const outer = topLevel(block)
  const needle = needleOf(chat)
  const span =
    wrapQuote(outer, needle, chat.occurrence || 1, 'ask-anchor') ??
    wrapQuote(block, needle, 1, 'ask-anchor')
  if (!span) return null
  for (const piece of document.querySelectorAll('.ask-anchor:not([data-ask])')) piece.dataset.ask = chat.id
  return span
}

/// Which chats the document's marks were last made for. The document is only
/// touched when that changes, or after a render replaced it: a list of chats
/// arriving after every answer used to unwrap and rewrap every passage, which
/// is a change to the document each time for nothing.
let anchoredFor = null

function anchorAll() {
  const wanted = config.enabled ? all().filter((chat) => chat.quote && (chat.turns.length || chat === draft)) : []
  const key = wanted.map((chat) => chat.id).sort().join(' ')
  if (key !== anchoredFor) {
    unwrapAnchors()
    for (const chat of wanted) wrap(chat)
    anchoredFor = key
  }
  document.querySelectorAll('.ask-anchor').forEach((span) => {
    span.classList.toggle('is-open', span.dataset.ask === shown?.id)
  })
  placeMarks()
}

/* ---------------------------------------------------------------- marks */

const marks = new Map()

/// One mark per chat with a passage, beside it in the right margin. Moved
/// rather than rebuilt: this runs whenever the column changes size.
///
/// Out in the margin when there is room; in the note dots' column when there
/// is not, as at Full width, where the margin is 48 points and the last 15 of
/// them are the scroller's — a mark there could not be clicked. A mark that
/// would sit on a note's dot moves down below it.
function placeMarks() {
  if (!layer) return
  const live = new Set()
  if (config.enabled) {
    const root = deps.content().getBoundingClientRect()
    const panelOpen = document.documentElement.dataset.askPanel === 'open'
    const visibleRight = panelOpen && panel ? window.innerWidth - panel.offsetWidth - 4 : window.innerWidth - 17
    const left = Math.min(root.right + 26, visibleRight - 24) + window.scrollX
    const dots = [...document.querySelectorAll('.note-dot')].map((dot) => {
      const box = dot.getBoundingClientRect()
      return { left: box.left + window.scrollX, right: box.right + window.scrollX, top: box.top + window.scrollY, bottom: box.bottom + window.scrollY }
    })
    const taken = []
    for (const chat of chats) {
      if (!chat.turns.length) continue
      const span = document.querySelector(`.ask-anchor[data-ask="${chat.id}"]`)
      const box = span?.getBoundingClientRect()
      if (!box?.height) continue
      let top = box.top + window.scrollY + (box.height - 22) / 2
      const clash = (t) =>
        taken.some((other) => Math.abs(other - t) < 24) ||
        dots.some((d) => d.right > left && d.left < left + 22 && d.bottom > t && d.top < t + 22)
      for (let tries = 0; tries < 6 && clash(top); tries += 1) top += 20
      taken.push(top)
      let mark = marks.get(chat.id)
      if (!mark) {
        mark = document.createElement('button')
        mark.type = 'button'
        mark.className = 'ask-mark'
        mark.dataset.ask = chat.id
        mark.setAttribute('aria-label', 'Open the chat about this passage')
        // The toolbar's own glyph, as a mask in the mark's colour.
        mark.innerHTML = config.glyph ? '<span class="ask-glyph" aria-hidden="true"></span>' : icon('ask', 16, 1.8)
        layer.appendChild(mark)
        marks.set(chat.id, mark)
      }
      mark.title = chat.turns[0]?.question ?? ''
      mark.style.top = `${top}px`
      mark.style.left = `${left}px`
      mark.classList.toggle('is-open', chat.id === shown?.id)
      mark.classList.toggle('is-running', !!chat.running)
      live.add(chat.id)
    }
  }
  for (const [id, mark] of marks) {
    if (live.has(id)) continue
    mark.remove()
    marks.delete(id)
  }
}

/* ---------------------------------------------------------------- views */

/// What the chat is about, and under which heading, on a line of its own: a
/// long passage wraps, and a heading run on after it started the next line
/// with a stray separator.
function aboutLine(chat) {
  const section = chat.section ? `<div class="ask-section">${icon('outline', 12)}<span>${escapeHtml(chat.section)}</span></div>` : ''
  if (!chat.quote) return `<div class="ask-about"><span>About the whole document</span></div>`
  const quote = chat.quote.length > 120 ? `${chat.quote.slice(0, 120)}…` : chat.quote
  return `<div class="ask-about"><div><span class="ask-about-label">About</span> <span class="ask-quote">${escapeHtml(quote)}</span></div>${section}</div>`
}

function activityHTML(chat, index) {
  const turn = chat.turns[index]
  const items = turn.activity ?? []
  const running = chat.running && index === chat.turns.length - 1
  if (!items.length && !running) return ''
  const lines = items
    .map((a) => `<div class="ask-act">${icon(a.kind === 'read' ? 'book' : a.kind === 'outline' ? 'outline' : 'search', 13)}<span>${escapeHtml(a.text)}</span></div>`)
    .join('')
  if (running) {
    const doing = items.length ? 'Working' : 'Thinking'
    const since = turn.started ?? chat.updated ?? Date.now()
    const waiting = turn.answer ? '' : `<div class="ask-act is-waiting"><span class="ask-spinner"></span><span>${doing}… <span class="ask-elapsed" data-since="${since}">${elapsed(since)}</span></span></div>`
    return `<div class="ask-activity">${lines}${waiting}</div>`
  }
  const key = `${chat.id}:${index}`
  if (expanded.has(key)) {
    return `<div class="ask-activity"><button type="button" class="ask-fold" data-action="fold" data-turn="${index}" aria-expanded="true">${icon('chevron', 11, 2)}<span>Hide</span></button>${lines}</div>`
  }
  const reads = items.filter((a) => a.kind === 'read').length
  const searches = items.filter((a) => a.kind === 'search').length
  const summary =
    items.length === 1
      ? escapeHtml(items[0].text)
      : [searches && `searched ${searches === 1 ? 'once' : `${searches} times`}`, reads && `read ${reads === 1 ? 'once' : `${reads} times`}`]
          .filter(Boolean)
          .join(', ')
          .replace(/^./, (c) => c.toUpperCase()) || `Looked in ${items.length} places`
  return `<button type="button" class="ask-fold" data-action="fold" data-turn="${index}" aria-expanded="false">${icon('search', 13)}<span>${summary}</span>${icon('chevron', 11, 2)}</button>`
}

const elapsed = (since) => `${Math.max(0, Math.round((Date.now() - since) / 1000))} s`

/// Ticks the seconds on every chat still waiting. A reasoning model can say
/// nothing for a quarter of a minute, and a spinner alone looks the same
/// whether it is thinking or stuck.
function tick() {
  document.querySelectorAll('.ask-elapsed').forEach((el) => {
    el.textContent = elapsed(Number(el.dataset.since))
  })
}

function answerHTML(turn) {
  if (!turn.answer) return ''
  return `<div class="ask-answer">${answerMd.render(turn.answer)}</div>`
}

function errorHTML(chat, index) {
  const turn = chat.turns[index]
  // Asked, and then the window closed or the app quit before anything came
  // back: the question is kept, and says it went unanswered.
  // Shown, never stored: a turn drawn once before its answer arrived kept the
  // words under the answer when it came.
  const unanswered = !turn.answer && !turn.error && !(chat.running && index === chat.turns.length - 1)
  const message = turn.error ?? (unanswered ? 'No answer arrived before the chat was closed.' : null)
  if (!message) return ''
  const last = index === chat.turns.length - 1
  const settings = turn.remedy === 'settings' || turn.remedy === 'install' ? `<button type="button" class="ask-link" data-action="settings">Settings…</button>` : ''
  const retry = last ? `<button type="button" class="ask-plain" data-action="retry">Try Again</button>` : ''
  return `<div class="ask-error" role="alert"><div class="ask-error-text">${icon('warning', 14)}<span>${escapeHtml(message)}</span></div>${retry || settings ? `<div class="ask-error-actions">${retry}${settings}</div>` : ''}</div>`
}

function actionsHTML(chat, index) {
  const turn = chat.turns[index]
  if (!turn.answer || (chat.running && index === chat.turns.length - 1)) return ''
  const last = index === chat.turns.length - 1
  const meta = config.showUsage && turn.usage ? `<button type="button" class="ask-meta" data-action="usage" data-turn="${index}" aria-label="Usage of this answer">${escapeHtml(metaLine(turn.usage))}</button>` : ''
  return `<div class="ask-actions">${iconButton('copy', 'Copy answer', 'copy')}${iconButton('note', 'Keep as a note on this passage', 'keep')}${last ? iconButton('retry', 'Ask again', 'retry') : ''}${meta}</div>`
}

function turnHTML(chat, index) {
  const turn = chat.turns[index]
  return `<div class="ask-turn" data-turn="${index}">
<div class="ask-q"><div class="ask-bubble">${escapeHtml(turn.question)}</div></div>
${activityHTML(chat, index)}
<div class="ask-answer-slot">${answerHTML(turn)}</div>
${errorHTML(chat, index)}
${actionsHTML(chat, index)}
</div>`
}

const PRESETS = {
  word: ['Define', 'In simpler words', 'An example', 'Why it matters here'],
  passage: ['Explain', 'In simpler words', 'Summarise', 'Why it matters here'],
  document: ['Summarise', 'What does it decide?', 'What is still open?'],
}

/// The app writes these, in English, so the answer would come back in English
/// whatever the reader reads in. They ask for the document's language instead.
const presetQuestion = (label, chat) => `${presetText(label, chat)} Answer in the language the document is written in.`

const presetText = (label, chat) => {
  const about = chat.quote ? `“${chat.quote.slice(0, 200)}”` : 'this document'
  switch (label) {
    case 'Define': return `Define ${about} as this document uses it.`
    case 'Explain': return `Explain ${about}.`
    case 'In simpler words': return `Say ${about} in simpler words.`
    case 'An example': return `Give an example of ${about}.`
    case 'Why it matters here': return `Why does ${about} matter here?`
    case 'Summarise': return `Summarise ${about}.`
    case 'What does it decide?': return 'What does this document decide?'
    case 'What is still open?': return 'What does this document leave open?'
    default: return label
  }
}

function composerHTML(chat) {
  const first = !chat.turns.length
  const running = chat.running
  const kind = !chat.quote ? 'document' : chat.quote.split(/\s+/).length <= 3 ? 'word' : 'passage'
  const chips = first
    ? `<div class="ask-chips">${PRESETS[kind].map((p) => `<button type="button" class="ask-chip" data-action="preset" data-preset="${p}">${p}</button>`).join('')}</div>`
    : ''
  const placeholder = running ? 'The next question, once this answer is in…' : first ? (chat.quote ? `Ask about “${chat.quote.length > 30 ? `${chat.quote.slice(0, 30)}…` : chat.quote}”…` : 'Ask about the document…') : 'Ask a follow-up…'
  const button = running
    ? `<button type="button" class="ask-send is-stop" data-action="stop" aria-label="Stop" title="Stop">${icon('stop', 14)}</button>`
    : `<button type="button" class="ask-send" data-action="send" aria-label="Ask" title="Ask (↵)" disabled>${icon('up', 14, 2)}</button>`
  const sees = config.sees
    ? `<span class="ask-sees" title="${escapeHtml(config.seesDetail ?? config.sees)}">${icon(config.sees.startsWith('Can') ? 'search' : config.sees.includes('section') ? 'book' : 'doc', 12)}<span class="ask-sees-text">${escapeHtml(config.sees)}</span></span>`
    : ''
  const model = config.available
    ? `<button type="button" class="ask-model" data-action="pick" aria-label="Choose the assistant" title="${escapeHtml(config.assistant)}"><span class="ask-model-name">${escapeHtml(config.assistant)}</span>${icon('chevron', 11, 2)}</button>`
    : `<button type="button" class="ask-model" data-action="settings"><span class="ask-model-name">Set up an assistant…</span></button>`
  const hint = first && !running ? `<div class="ask-hint">↵ ask · ⇧↵ new line · esc close</div>` : ''
  return `<div class="ask-composer">${chips}
<div class="ask-box${first ? ' is-first' : ''}">
<div class="ask-row"><textarea rows="1" aria-label="Question" placeholder="${escapeHtml(placeholder)}"></textarea>${button}</div>
<div class="ask-foot">${model}${sees}</div>
</div>${hint}</div>`
}

function threadHTML(chat) {
  return chat.turns.map((_, index) => turnHTML(chat, index)).join('')
}

function fillChat(host, chat, mode) {
  closeUsage()
  const total = config.showUsage ? totalLine(chat) : ''
  const head =
    mode === 'card'
      ? `<div class="ask-head"><span class="ask-label">Ask</span><span class="ask-grow"></span>${total ? `<button type="button" class="ask-meta" data-action="chat-usage" aria-label="Usage of this chat">${escapeHtml(total)}</button>` : ''}${iconButton('panel', 'Move to the side panel', 'to-panel')}${iconButton('close', 'Close (esc)', 'close')}</div>`
      : ''
  const typed = host.querySelector('textarea')?.value ?? drafts.get(chat.id) ?? ''
  host.innerHTML = `${head}${aboutLine(chat)}<div class="ask-thread">${threadHTML(chat)}</div>${composerHTML(chat)}`
  host.dataset.chat = chat.id
  const field = host.querySelector('textarea')
  if (field) {
    field.value = typed
    grow(field)
    ready(field)
  }
  decorate(host, chat)
}

/// The arrow is live only with something to send.
function ready(field) {
  const button = field.closest('.ask-box')?.querySelector('.ask-send:not(.is-stop)')
  if (button) button.disabled = !field.value.trim()
}

/// Line citations become numbered chips: [L42] and [L40-44] as the prompt asks
/// for them. Hover says which lines, a click takes the page there.
function decorate(host, chat) {
  host.querySelectorAll('.ask-answer').forEach((answer) => {
    const numbers = new Map()
    const walker = document.createTreeWalker(answer, NodeFilter.SHOW_TEXT)
    const nodes = []
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.parentElement.closest('code, pre, a, .katex')) nodes.push(node)
    }
    // [L42], [L40-44], and the lists models write as well: [L393, L516, L729].
    const pattern = /\[(L\d+(?:\s*[-–]\s*L?\d+)?(?:\s*[,;]\s*L?\d+(?:\s*[-–]\s*L?\d+)?)*)\]/g
    for (const node of nodes) {
      const text = node.data
      if (!pattern.test(text)) continue
      pattern.lastIndex = 0
      const fragment = document.createDocumentFragment()
      let at = 0
      for (const match of text.matchAll(pattern)) {
        fragment.append(text.slice(at, match.index).replace(/\s+$/, ' '))
        for (const part of match[1].split(/\s*[,;]\s*/)) {
          const [from, to] = part.replace(/L/g, '').split(/\s*[-–]\s*/).map(Number)
          const key = `${from}-${to ?? from}`
          if (!numbers.has(key)) numbers.set(key, numbers.size + 1)
          const chip = document.createElement('button')
          chip.type = 'button'
          chip.className = 'ask-cite'
          chip.dataset.action = 'cite'
          chip.dataset.from = String(from)
          chip.dataset.to = String(to ?? from)
          chip.textContent = String(numbers.get(key))
          chip.title = citeTitle(from, to ?? from)
          chip.setAttribute('aria-label', `Show line ${to && to !== from ? `${from} to ${to}` : from} in the document`)
          fragment.append(chip)
        }
        at = match.index + match[0].length
      }
      fragment.append(text.slice(at))
      node.replaceWith(fragment)
    }
  })
  if (chat) host.querySelectorAll('.ask-answer a').forEach((a) => a.setAttribute('title', a.getAttribute('href') ?? ''))
  fitTables(host)
}

/// A table is left as a table while it fits. One that does not is laid out
/// again for the space there is, rather than the model being told to avoid
/// tables — it would not always listen, and the table is often the right
/// answer: two columns become pairs, a term over what it means; more become
/// one card per row, each value under its column's name.
function fitTables(host) {
  host.querySelectorAll('.ask-answer table').forEach((table) => {
    table.classList.remove('is-pairs', 'is-stacked')
    const headers = [...table.querySelectorAll('thead th')].map((th) => th.textContent.trim())
    for (const row of table.querySelectorAll('tbody tr')) {
      ;[...row.children].forEach((cell, index) => {
        if (headers[index]) cell.dataset.label = headers[index]
      })
    }
    // Measured in the table's own text: what matters is how many words a line
    // of the narrowest column can hold, not how many points it has.
    const em = parseFloat(getComputedStyle(table).fontSize) || 14
    const columns = Math.max(headers.length, table.querySelector('tr')?.children.length ?? 1)
    const overflows = table.scrollWidth > table.clientWidth + 2
    const cramped = columns === 2 ? table.clientWidth < 30 * em : table.clientWidth / columns < 10 * em
    if (overflows || cramped) table.classList.add(columns === 2 ? 'is-pairs' : 'is-stacked')
  })
}

function citeTitle(from, to) {
  const lines = deps.sourceLines()
  const text = lines[from - 1]?.trim() ?? ''
  const where = from === to ? `Line ${from}` : `Lines ${from}–${to}`
  return text ? `${where}: ${text.length > 160 ? `${text.slice(0, 160)}…` : text}` : where
}

/// Takes the page to the lines a citation names and lights them up for a
/// moment, the way a link to a heading lands on it.
function goToLines(from) {
  const line = from - 1
  let target = null
  let span = Infinity
  for (const el of deps.content().querySelectorAll('[data-line]')) {
    const range = deps.lineRange(el)
    if (!range || range.start > line || range.end <= line) continue
    const size = range.end - range.start
    if (size <= span) {
      target = el
      span = size
    }
  }
  if (!target) return
  const top = target.getBoundingClientRect().top + window.scrollY - deps.topInset() - 96
  deps.glideTo(Math.max(0, top))
  target.classList.remove('ask-flash')
  void target.offsetWidth
  target.classList.add('ask-flash')
  setTimeout(() => target.classList.remove('ask-flash'), 1800)
}

function grow(field) {
  field.style.height = 'auto'
  field.style.height = `${Math.min(field.scrollHeight, 160)}px`
}

/* ----------------------------------------------------------------- card */

function openCard(chat) {
  closeUsage()
  if (showsIn === 'card' && shown !== chat) closeCard({ keep: chat })
  if (!card) {
    card = document.createElement('section')
    card.className = 'ask-card'
    card.setAttribute('aria-label', 'Ask')
    layer.appendChild(card)
  }
  shown = chat
  showsIn = 'card'
  fillChat(card, chat, 'card')
  anchorAll()
  placeCard()
  scrollToLatest()
  revealCard()
  focusComposer()
}

/// A card opened on the last lines of the screen would hang below it. The page
/// moves up by as much as it needs and no further than keeps the passage
/// itself in sight under the toolbar.
function revealCard() {
  const box = card.getBoundingClientRect()
  const overflow = box.bottom - (window.innerHeight - 12)
  if (overflow <= 0) return
  const anchor = document.querySelector(`.ask-anchor[data-ask="${shown.id}"]`)?.getBoundingClientRect()
  const room = anchor ? anchor.top - deps.topInset() - 24 : overflow
  if (room > 0) window.scrollBy(0, Math.min(overflow, room))
}

let showsIn = null

/// Under the passage's last line, running from inside the column out into the
/// right margin: close enough to read as belonging to the words, far enough
/// right to leave the start of the next lines showing.
function placeCard() {
  if (!card || showsIn !== 'card' || !shown) return
  const spans = [...document.querySelectorAll(`.ask-anchor[data-ask="${shown.id}"]`)]
  const last = spans[spans.length - 1]
  const root = deps.content().getBoundingClientRect()
  // Its width comes from the stylesheet, which follows the text size.
  const width = card.offsetWidth
  const right = Math.min(root.right + 64, window.innerWidth - 18)
  const left = Math.max(16, right - width)
  const box = last?.getBoundingClientRect()
  const top = box ? box.bottom + window.scrollY + 8 : window.scrollY + deps.topInset() + 24
  card.style.left = `${left + window.scrollX}px`
  card.style.top = `${top}px`
}

/// The card goes, the chat stays: it is in the list and its mark is in the
/// margin. A draft nobody asked anything in simply goes — unless it is the chat
/// about to be shown somewhere else, which is `keep`.
function closeCard({ keep = null } = {}) {
  if (showsIn !== 'card') return
  closeUsage()
  const leaving = shown
  const field = card?.querySelector('textarea')
  if (leaving && field) drafts.set(leaving.id, field.value)
  card?.remove()
  card = null
  shown = null
  showsIn = null
  if (leaving && leaving !== keep) {
    if (leaving === draft) draft = null
    else bridge({ op: 'closed', chat: leaving.id })
  }
  anchorAll()
}

function closeView() {
  closeCard()
  document.activeElement?.blur?.()
}

/* ---------------------------------------------------------------- panel */

function ensurePanel() {
  if (panel) return panel
  panel = document.createElement('aside')
  panel.className = 'ask-panel'
  panel.setAttribute('aria-label', 'Ask')
  document.body.appendChild(panel)
  return panel
}

function openPanel(chat) {
  closeUsage()
  const target = chat ?? (showsIn === 'card' ? shown : null)
  if (showsIn === 'card') closeCard({ keep: target })
  const opening = document.documentElement.dataset.askPanel !== 'open'
  ensurePanel()
  if (opening) {
    deps.keepingPlace(() => {
      document.documentElement.dataset.askPanel = 'open'
    })
    bridge({ op: 'panel', open: true })
  }
  if (showsIn === 'panel' && shown && shown !== target && shown === draft && !shown.turns.length) draft = null
  shown = target ?? (showsIn === 'panel' ? shown : null) ?? latestChat() ?? documentDraft()
  showsIn = 'panel'
  fillPanel()
  scrollToLatest()
  anchorAll()
  placeCard()
  focusComposer()
}

function closePanel() {
  if (document.documentElement.dataset.askPanel !== 'open') return
  closeUsage()
  const field = panel?.querySelector('textarea')
  if (shown && field) drafts.set(shown.id, field.value)
  const leaving = shown
  deps.keepingPlace(() => {
    delete document.documentElement.dataset.askPanel
  })
  if (leaving === draft) draft = null
  else if (leaving) bridge({ op: 'closed', chat: leaving.id })
  if (showsIn === 'panel') {
    shown = null
    showsIn = null
  }
  listOpen = false
  bridge({ op: 'panel', open: false })
  anchorAll()
}

const latestChat = () => [...chats].sort((a, b) => b.updated - a.updated)[0] ?? null

function documentDraft() {
  draft = { id: newId(), quote: '', line: null, end: null, blockEnd: null, occurrence: 1, section: '', created: Date.now(), updated: Date.now(), assistant: '', model: '', turns: [], running: false }
  return draft
}

function fillPanel() {
  if (!panel) return
  closeUsage()
  const chat = shown
  const total = chat && config.showUsage ? totalLine(chat) : ''
  const count = chats.filter((c) => c.turns.length).length
  const list = listOpen ? listHTML() : ''
  panel.innerHTML = `<div class="ask-resize" aria-hidden="true" title="Drag to resize"></div><div class="ask-panel-head">
<button type="button" class="ask-chats" data-action="list" aria-expanded="${listOpen}" title="Chats about this document">Chats<span class="ask-count">${count}</span>${icon('chevron', 12, 2)}</button>
<span class="ask-grow"></span>
${total ? `<button type="button" class="ask-meta" data-action="chat-usage" aria-label="Usage of this chat">${escapeHtml(total)}</button>` : ''}
${iconButton('plus', 'New chat about the document', 'new')}${iconButton('close', 'Close the panel', 'close-panel')}
</div>${list}<div class="ask-panel-body"></div>`
  const body = panel.querySelector('.ask-panel-body')
  if (chat) fillChat(body, chat, 'panel')
}

function listHTML() {
  const rows = chats
    .filter((c) => c.turns.length)
    .sort((a, b) => b.updated - a.updated)
    .map((c) => {
      const t = chatTotals(c)
      const price = t ? (t.local ? 'local' : money(t.cost)) : null
      return `<div class="ask-row-item${c.id === shown?.id ? ' is-current' : ''}">
<button type="button" class="ask-open" data-action="open" data-chat="${c.id}">
<span class="ask-row-top"><span class="ask-row-quote">${c.quote ? `“${escapeHtml(c.quote.length > 40 ? `${c.quote.slice(0, 40)}…` : c.quote)}”` : 'The whole document'}</span><span class="ask-row-when">${ago(c.updated)}${price ? ` · ${price}` : ''}</span></span>
<span class="ask-row-q">${escapeHtml(c.turns[0]?.question ?? '')}</span>
</button>${iconButton('trash', 'Delete this chat', 'delete', 'ask-row-delete')}</div>`
    })
    .join('')
  return `<div class="ask-list">${rows || '<div class="ask-empty">No chats about this document yet.</div>'}${rows ? '<div class="ask-list-foot"><button type="button" class="ask-plain" data-action="delete-all">Delete All…</button></div>' : ''}</div>`
}

/* ------------------------------------------------------------ usage tips */

function closeUsage() {
  usageTip?.remove()
  usageTip = null
  document.querySelectorAll('.ask-meta[aria-expanded="true"]').forEach((b) => b.setAttribute('aria-expanded', 'false'))
}

function statRow(label, value, note = '') {
  return `<span class="ask-stat-label">${label}</span><span class="ask-stat-value">${value}${note ? ` <span class="ask-stat-note">${note}</span>` : ''}</span>`
}

function meter(used, window) {
  if (used == null) return ''
  const pct = window ? Math.min(100, Math.max(1, (used / window) * 100)) : null
  return `<div class="ask-meter"><div class="ask-meter-row"><span>Context used</span><span>${whole(used)}${window ? ` of ${whole(window)}` : ''}</span></div>${pct ? `<div class="ask-meter-bar"><div style="width:${pct.toFixed(1)}%"></div></div>` : ''}</div>`
}

function answerUsageHTML(chat, index) {
  const u = chat.turns[index].usage
  if (!u) return ''
  const acts = chat.turns[index].activity ?? []
  const count = (kind) => acts.filter((a) => a.kind === kind).length
  const opened = [
    count('search') && `searched ${count('search') === 1 ? 'once' : `${count('search')} times`}`,
    count('read') && `read ${count('read') === 1 ? 'once' : `${count('read')} times`}`,
    count('outline') && 'looked at the headings',
  ].filter(Boolean).join(', ')
  const speed = u.output != null && u.seconds != null && u.firstToken != null && u.seconds > u.firstToken ? Math.round(u.output / (u.seconds - u.firstToken)) : null
  const cost = u.local ? statRow('Cost', 'Nothing', 'runs on this Mac') : u.cost != null ? statRow('Cost', money(u.cost), u.costSource ? `reported by ${escapeHtml(u.costSource)}` : '') : statRow('Cost', 'Not reported')
  const by = chat.turns[index].by
  return `<div class="ask-tip-title">This answer</div><div class="ask-stats">
${by ? statRow('Answered by', escapeHtml(by)) : ''}
${statRow('Input', `${whole(u.input)} tokens`, u.cachedInput ? `${whole(u.cachedInput)} from cache` : '')}
${statRow('Output', `${whole(u.output)} tokens`, u.reasoning ? `${whole(u.reasoning)} of them reasoning` : '')}
${statRow('Document', opened ? opened.replace(/^./, (c) => c.toUpperCase()) : 'Not opened', opened ? '' : 'the answer rests on the passage it was given')}
${statRow('Requests', String(u.rounds ?? 1))}
${u.seconds != null ? statRow('Time', seconds(u.seconds), u.firstToken != null ? `first word after ${seconds(u.firstToken)}` : '') : ''}
${speed ? statRow('Speed', `${speed} tokens/s`) : ''}
${cost}
</div>${meter(u.context, u.window)}`
}

function chatUsageHTML(chat) {
  const answered = chat.turns.map((turn, index) => ({ turn, index })).filter(({ turn }) => turn.usage)
  const t = chatTotals(chat)
  if (!t) return ''
  const rows = answered
    .map(({ turn }) => `<span class="ask-cell-q">${escapeHtml(turn.question)}</span><span>${whole(turn.usage.input)}</span><span>${whole(turn.usage.output)}</span><span>${turn.usage.local ? 'local' : money(turn.usage.cost) ?? '—'}</span>`)
    .join('')
  const last = answered[answered.length - 1]?.turn.usage
  const note = answered.length > 1 ? `<div class="ask-tip-note">${t.cached ? `${whole(t.cached)} of the input tokens came from the cache. ` : ''}Each question sends the chat so far again, so the input grows with every turn.</div>` : ''
  return `<div class="ask-tip-title">This chat · ${answered.length} ${answered.length === 1 ? 'answer' : 'answers'}</div>
<div class="ask-table"><span class="ask-th">Question</span><span class="ask-th">In</span><span class="ask-th">Out</span><span class="ask-th">Cost</span>${rows}
<span class="ask-total">Total</span><span class="ask-total">${whole(t.input)}</span><span class="ask-total">${whole(t.output)}</span><span class="ask-total">${t.local ? 'local' : money(t.cost) ?? '—'}</span></div>${note}${meter(last?.context, last?.window)}`
}

function toggleUsage(button, html) {
  if (usageTip && usageTip.dataset.for === button.dataset.action + (button.dataset.turn ?? '')) return closeUsage()
  closeUsage()
  if (!html) return
  usageTip = document.createElement('div')
  usageTip.className = 'ask-tip'
  usageTip.setAttribute('role', 'dialog')
  usageTip.dataset.for = button.dataset.action + (button.dataset.turn ?? '')
  usageTip.innerHTML = html
  document.body.appendChild(usageTip)
  button.setAttribute('aria-expanded', 'true')
  const box = button.getBoundingClientRect()
  const width = Math.min(340, window.innerWidth - 24)
  usageTip.style.width = `${width}px`
  const left = Math.max(12, Math.min(box.right - width, window.innerWidth - width - 12))
  const height = usageTip.offsetHeight
  const below = box.bottom + 6
  const top = below + height < window.innerHeight - 8 ? below : Math.max(deps.topInset() + 8, box.top - height - 6)
  // From the panel, pinned to the window as the panel is; from the card, to
  // the page, which is what the card scrolls with. Either way it goes as soon
  // as anything scrolls (see installAsk): left behind, it pointed at nothing.
  const fixed = !!button.closest('.ask-panel')
  usageTip.style.position = fixed ? 'fixed' : 'absolute'
  usageTip.style.left = `${left + (fixed ? 0 : window.scrollX)}px`
  usageTip.style.top = `${top + (fixed ? 0 : window.scrollY)}px`
}

/* -------------------------------------------------------------- actions */

function focusComposer() {
  const host = showsIn === 'card' ? card : panel
  const field = host?.querySelector('textarea')
  if (field) setTimeout(() => field.focus({ preventScroll: true }), 0)
}

function send(chat, question) {
  const text = question.trim()
  if (!text || chat.running) return
  if (!config.available) return bridge({ op: 'settings' })
  if (chat === draft) {
    chats.push(chat)
    draft = null
  }
  const host = showsIn === 'card' ? card : panel?.querySelector('.ask-panel-body')
  const field = host?.querySelector('textarea')
  if (field) field.value = ''
  chat.turns.push({ question: text, answer: '', activity: [], usage: null, error: null, started: Date.now() })
  chat.running = true
  chat.updated = Date.now()
  drafts.delete(chat.id)
  bridge({
    op: 'send',
    question: text,
    chat: { id: chat.id, quote: chat.quote, line: chat.line, end: chat.end, blockEnd: chat.blockEnd, occurrence: chat.occurrence, section: chat.section },
  })
  refresh(chat)
  anchorAll()
  scrollThreadToEnd()
}

/// Opening a chat shows its last question and the start of its answer, not
/// the bottom of a long answer with its beginning scrolled away.
function scrollToLatest() {
  const thread = showsIn === 'card' ? card?.querySelector('.ask-thread') : panel?.querySelector('.ask-panel-body .ask-thread')
  const last = thread?.querySelector('.ask-turn:last-child')
  if (!thread || !last) return
  thread.scrollTop = Math.max(0, last.offsetTop - thread.offsetTop - 4)
}

function scrollThreadToEnd() {
  const thread = showsIn === 'card' ? card?.querySelector('.ask-thread') : panel?.querySelector('.ask-panel-body .ask-thread')
  if (thread) thread.scrollTop = thread.scrollHeight
}

/// Whether the reader is at the end of the thread, where new words should keep
/// them. Scrolled up to reread something, they stay put.
function atEnd() {
  const thread = showsIn === 'card' ? card?.querySelector('.ask-thread') : panel?.querySelector('.ask-panel-body .ask-thread')
  return !thread || thread.scrollHeight - thread.scrollTop - thread.clientHeight < 40
}

/// Redraws wherever the chat is showing. The panel's list is redrawn with it,
/// since the chat's time and cost are on it.
function refresh(chat) {
  if (!chat || chat !== shown) return
  const bottom = atEnd()
  if (showsIn === 'card' && card) {
    fillChat(card, chat, 'card')
    placeCard()
  } else if (showsIn === 'panel' && panel) {
    fillPanel()
  }
  if (bottom) scrollThreadToEnd()
}

function hostOf(chat) {
  if (!chat || chat !== shown) return null
  if (showsIn === 'card') return card
  if (showsIn === 'panel') return panel?.querySelector('.ask-panel-body')
  return null
}

const fromHTML = (html) => {
  const holder = document.createElement('div')
  holder.innerHTML = html.trim()
  return holder.firstElementChild
}

/// One turn redrawn where it is, the rest of the chat left alone. Redrawing
/// the whole panel on every event rebuilt everything in it, several times a
/// second while an answer arrived.
function updateTurn(chat, index) {
  const host = hostOf(chat)
  if (!host) return
  const old = host.querySelector(`.ask-turn[data-turn="${index}"]`)
  if (!old) return refresh(chat)
  const bottom = atEnd()
  const fresh = fromHTML(turnHTML(chat, index))
  old.replaceWith(fresh)
  decorate(fresh, chat)
  if (bottom) scrollThreadToEnd()
}

function updateComposer(chat) {
  const old = hostOf(chat)?.querySelector('.ask-composer')
  if (!old) return
  const typed = old.querySelector('textarea')?.value ?? ''
  const fresh = fromHTML(composerHTML(chat))
  old.replaceWith(fresh)
  const field = fresh.querySelector('textarea')
  if (field) {
    field.value = typed
    grow(field)
    ready(field)
  }
}

/// The chat's running total, in the card's head or the panel's.
function updateTotals(chat) {
  if (chat !== shown) return
  const head = showsIn === 'card' ? card?.querySelector('.ask-head') : panel?.querySelector('.ask-panel-head')
  if (!head) return
  const total = config.showUsage ? totalLine(chat) : ''
  let meta = head.querySelector('.ask-meta')
  if (!total) return meta?.remove()
  if (!meta) {
    meta = fromHTML(`<button type="button" class="ask-meta" data-action="chat-usage" aria-label="Usage of this chat"></button>`)
    head.querySelector('.ask-icon')?.before(meta)
  }
  meta.textContent = total
}

/// Only the answer that is growing, a few times a second: redrawing the whole
/// chat on every word would redraw every earlier answer with it.
function refreshAnswer(chat) {
  if (!chat || chat !== shown) return
  clearTimeout(renderTimer)
  renderTimer = setTimeout(() => {
    const host = showsIn === 'card' ? card : panel?.querySelector('.ask-panel-body')
    const index = chat.turns.length - 1
    const turnEl = host?.querySelector(`.ask-turn[data-turn="${index}"]`)
    if (!turnEl) return refresh(chat)
    const bottom = atEnd()
    const slot = turnEl.querySelector('.ask-answer-slot')
    slot.innerHTML = answerHTML(chat.turns[index])
    decorate(slot, chat)
    const waiting = turnEl.querySelector('.is-waiting')
    if (waiting && chat.turns[index].answer) waiting.remove()
    if (bottom) scrollThreadToEnd()
  }, 40)
}

function handleClick(event) {
  const button = event.target.closest('[data-action]')
  const inside = event.target.closest('.ask-card, .ask-panel, .ask-tip')
  if (!inside && !event.target.closest('.ask-mark, .ask-anchor')) {
    if (usageTip) closeUsage()
    if (listOpen) {
      listOpen = false
      fillPanel()
    }
  }
  // A passage with a note on it opens the note, as it did before it had a
  // chat too; the chat is a click away on its mark.
  const mark =
    event.target.closest('.ask-mark') ??
    (event.target.closest('.note-anchor') ? null : event.target.closest('.ask-anchor[data-ask]'))
  if (mark && !button && window.getSelection().isCollapsed) {
    event.preventDefault()
    event.stopPropagation()
    const chat = find(mark.dataset.ask)
    if (!chat) return
    if (shown === chat && showsIn === 'card') return closeView()
    return showsIn === 'panel' ? openPanel(chat) : openCard(chat)
  }
  if (!button || !inside) return
  event.preventDefault()
  event.stopPropagation()
  const host = button.closest('[data-chat]')
  const chat = host ? find(host.dataset.chat) : shown
  const index = Number(button.dataset.turn ?? button.closest('.ask-turn')?.dataset.turn ?? -1)
  switch (button.dataset.action) {
    case 'send': {
      const field = host?.querySelector('textarea')
      if (chat && field) send(chat, field.value)
      break
    }
    case 'preset':
      if (chat) send(chat, presetQuestion(button.dataset.preset, chat))
      break
    case 'stop':
      if (chat) bridge({ op: 'stop', chat: chat.id })
      break
    case 'close':
      closeView()
      break
    case 'to-panel':
      openPanel(chat)
      break
    case 'close-panel':
      closePanel()
      break
    case 'new':
      listOpen = false
      shown = documentDraft()
      fillPanel()
      focusComposer()
      break
    case 'list':
      listOpen = !listOpen
      fillPanel()
      break
    case 'open': {
      listOpen = false
      const target = find(button.dataset.chat)
      if (target) openPanel(target)
      break
    }
    case 'delete': {
      const row = button.closest('.ask-row-item')?.querySelector('[data-chat]')
      const id = row?.dataset.chat
      if (!id) break
      bridge({ op: 'delete', chat: id })
      chats = chats.filter((c) => c.id !== id)
      if (shown?.id === id) shown = latestChat() ?? documentDraft()
      fillPanel()
      anchorAll()
      break
    }
    case 'delete-all':
      bridge({ op: 'deleteAll' })
      break
    case 'fold': {
      const key = `${chat.id}:${index}`
      if (expanded.has(key)) expanded.delete(key)
      else expanded.add(key)
      refresh(chat)
      break
    }
    case 'copy':
      if (chat?.turns[index]) bridge({ op: 'copy', text: chat.turns[index].answer })
      flash(button, 'Copied')
      break
    case 'keep':
      if (chat?.turns[index]) bridge({ op: 'keep', chat: chat.id, turn: index })
      break
    case 'retry':
      if (chat && !chat.running && chat.turns.length) {
        const last = chat.turns.pop()
        chat.turns.push({ question: last.question, answer: '', activity: [], usage: null, error: null, started: Date.now() })
        chat.running = true
        bridge({ op: 'retry', chat: chat.id })
        refresh(chat)
      }
      break
    case 'pick': {
      const box = button.getBoundingClientRect()
      bridge({ op: 'pick', chat: chat && chat !== draft ? chat.id : null, rect: { x: box.left, y: box.top, width: box.width, height: box.height } })
      break
    }
    case 'settings':
      bridge({ op: 'settings' })
      break
    case 'cite':
      goToLines(Number(button.dataset.from))
      break
    case 'usage':
      if (chat) toggleUsage(button, answerUsageHTML(chat, index))
      break
    case 'chat-usage':
      if (chat) toggleUsage(button, chatUsageHTML(chat))
      break
  }
}

function flash(button, text) {
  const was = button.getAttribute('title')
  button.classList.add('is-done')
  button.setAttribute('title', text)
  setTimeout(() => {
    button.classList.remove('is-done')
    button.setAttribute('title', was ?? '')
  }, 1200)
}

function handleKey(event) {
  const field = event.target.closest?.('.ask-card textarea, .ask-panel textarea')
  // Escape puts the card away and the answer goes on arriving: the mark pulses
  // until it is there. Stopping is the button's job, never a key's.
  if (event.key === 'Escape') {
    if (usageTip) {
      closeUsage()
    } else if (listOpen) {
      listOpen = false
      fillPanel()
    } else if (showsIn === 'card') {
      closeView()
    } else if (showsIn === 'panel' && (field || event.target.closest?.('.ask-panel'))) {
      closePanel()
    } else {
      return
    }
    event.preventDefault()
    event.stopPropagation()
    return
  }
  if (!field) return
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault()
    const host = field.closest('[data-chat]')
    const chat = host ? find(host.dataset.chat) : null
    // Typed while the answer is still coming: it stays in the field, and goes
    // with Return once the answer is in.
    if (chat && !chat.running) send(chat, field.value)
  }
}

/* ---------------------------------------------------------------- api */

function configure(next) {
  const glyph = config.glyph
  config = { ...config, ...next }
  if (config.glyph && config.glyph !== glyph) {
    document.documentElement.style.setProperty('--ask-glyph', `url("${config.glyph}")`)
    // Marks made before the glyph came wear the stand-in; they are made again.
    for (const mark of marks.values()) mark.innerHTML = '<span class="ask-glyph" aria-hidden="true"></span>'
  }
  if (!config.enabled) {
    closeCard()
    closePanel()
  }
  anchorAll()
  if (showsIn === 'card' && card && shown) fillChat(card, shown, 'card')
  if (showsIn === 'panel') fillPanel()
}

function setChats({ chats: next }) {
  const running = new Map(chats.filter((c) => c.running).map((c) => [c.id, c]))
  chats = next.map((chat) => {
    const live = running.get(chat.id)
    // A chat mid-answer keeps what the page already has: the store is written
    // once the answer is done, and a list sent before then is behind.
    return live ? live : chat
  })
  if (shown && shown !== draft) shown = chats.find((c) => c.id === shown.id) ?? null
  if (!shown && showsIn === 'card') {
    card?.remove()
    card = null
    showsIn = null
  }
  if (showsIn === 'panel' && !shown) shown = latestChat() ?? documentDraft()
  anchorAll()
  if (showsIn === 'card' && shown) fillChat(card, shown, 'card')
  if (showsIn === 'panel') fillPanel()
}

/// ⌘J: the selection if there is one, else back into the open chat, else the
/// panel.
function open({ selection }) {
  if (!config.enabled) return
  const info = selection ? deps.selectionInfo() : null
  if (info) {
    const existing = chats.find((c) => c.quote === info.text && c.line === info.inline?.start)
    if (existing) return showsIn === 'panel' ? openPanel(existing) : openCard(existing)
    if (draft && showsIn === 'card') closeCard()
    draft = {
      id: newId(),
      quote: info.text.length > 500 ? info.text.slice(0, 500) : info.text,
      line: info.inline?.start ?? info.block?.start ?? null,
      end: info.inline?.end ?? info.block?.end ?? null,
      blockEnd: info.block?.end ?? null,
      occurrence: info.occurrence ?? 1,
      section: sectionOf(window.getSelection().getRangeAt(0).startContainer),
      created: Date.now(),
      updated: Date.now(),
      assistant: '',
      model: '',
      turns: [],
      running: false,
    }
    window.getSelection().removeAllRanges()
    return showsIn === 'panel' ? openPanel(draft) : openCard(draft)
  }
  if (showsIn) return focusComposer()
  openPanel(null)
}

function togglePanel() {
  if (!config.enabled) return
  if (document.documentElement.dataset.askPanel === 'open') closePanel()
  else openPanel(null)
}

/// The heading a passage sits under, as the reader sees it.
function sectionOf(node) {
  const el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement
  let found = ''
  for (const heading of deps.content().querySelectorAll('h1, h2, h3, h4, h5, h6')) {
    if (heading.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING) found = heading.textContent.trim()
    else break
  }
  return found
}

function event(payload) {
  const chat = chats.find((c) => c.id === payload.chat) ?? (draft?.id === payload.chat ? draft : null)
  if (!chat) return
  const last = chat.turns.length - 1
  const turn = chat.turns[last]
  switch (payload.kind) {
    case 'asked':
      chat.running = true
      if (payload.assistant) chat.assistant = payload.assistant
      if (turn && !turn.started) turn.started = Date.now()
      updateTurn(chat, last)
      updateComposer(chat)
      return placeMarks()
    case 'activity':
      if (turn) turn.activity.push(payload.activity)
      return updateTurn(chat, last)
    case 'delta':
      if (turn) turn.answer += payload.text
      return refreshAnswer(chat)
    case 'restart':
      if (turn) turn.answer = ''
      return refreshAnswer(chat)
    case 'usage':
      if (turn) turn.usage = payload.usage
      return updateTotals(chat)
    case 'done':
    case 'stopped':
    case 'error':
      chat.running = false
      clearTimeout(renderTimer)
      if (payload.kind === 'error') {
        if (turn) {
          turn.error = payload.message
          turn.remedy = payload.remedy
        } else {
          chat.turns.push({ question: '', answer: '', activity: [], usage: null, error: payload.message, remedy: payload.remedy })
        }
      } else if (turn) {
        if (typeof payload.answer === 'string') turn.answer = payload.answer
        if (payload.kind === 'stopped' && !turn.answer) turn.error = 'Stopped.'
      }
      chat.updated = Date.now()
      updateTurn(chat, chat.turns.length - 1)
      updateComposer(chat)
      updateTotals(chat)
      if (listOpen) fillPanel()
      placeMarks()
      return focusComposer()
  }
}

/// Called by main.js once a render has attached the notes: the anchors and the
/// marks went out with the old DOM.
export function askAfterRender() {
  anchoredFor = null
  anchorAll()
  placeCard()
}

const WIDTH_KEY = 'imark.askPanelWidth'

function storedWidth() {
  try {
    return Number(localStorage.getItem(WIDTH_KEY)) || null
  } catch {
    return null
  }
}

/// Dragging moves only the panel; the document follows once, on release. A
/// long document laid out again on every movement of the mouse is a drag
/// that stutters.
function startResize(event, handle) {
  event.preventDefault()
  handle.classList.add('is-dragging')
  document.documentElement.dataset.askResizing = ''
  const clamp = (w) => Math.round(Math.max(320, Math.min(w, window.innerWidth * 0.62)))
  let width = panel.offsetWidth
  const move = (e) => {
    width = clamp(window.innerWidth - e.clientX)
    panel.style.width = `${width}px`
  }
  const up = () => {
    document.removeEventListener('mousemove', move, true)
    document.removeEventListener('mouseup', up, true)
    handle.classList.remove('is-dragging')
    delete document.documentElement.dataset.askResizing
    deps.keepingPlace(() => {
      document.documentElement.style.setProperty('--ask-panel-width', `${width}px`)
      panel.style.width = ''
    })
    fitTables(panel)
    try {
      localStorage.setItem(WIDTH_KEY, String(width))
    } catch {
      // A page that cannot remember keeps the width until it closes.
    }
    placeMarks()
  }
  document.addEventListener('mousemove', move, true)
  document.addEventListener('mouseup', up, true)
}

export function installAsk(dependencies) {
  deps = dependencies
  const width = storedWidth()
  if (width) document.documentElement.style.setProperty('--ask-panel-width', `${width}px`)
  setInterval(tick, 1000)
  document.addEventListener('mousedown', (event) => {
    const handle = event.target.closest?.('.ask-resize')
    if (handle && panel) startResize(event, handle)
  })
  layer = document.createElement('div')
  layer.className = 'ask-layer'
  document.body.appendChild(layer)
  document.addEventListener('click', handleClick, true)
  document.addEventListener('keydown', handleKey, true)
  document.addEventListener('input', (event) => {
    if (!event.target.matches?.('.ask-card textarea, .ask-panel textarea')) return
    grow(event.target)
    ready(event.target)
  })
  const reflow = () => {
    placeMarks()
    placeCard()
    closeUsage()
    if (card) fitTables(card)
    if (panel) fitTables(panel)
  }
  window.addEventListener('resize', reflow)
  // The panel is a surface of its own: a wheel over it never moves the
  // document behind it. overscroll-behavior only holds over the parts that
  // scroll, and the head, the passage, the field — or a chat too short to
  // scroll — passed the wheel straight through to the page.
  document.addEventListener(
    'wheel',
    (event) => {
      if (!event.target.closest?.('.ask-panel')) return
      const scroller = event.target.closest('.ask-thread, .ask-list, textarea, pre, table')
      const room = scroller && (event.deltaY ? scroller.scrollHeight > scroller.clientHeight : scroller.scrollWidth > scroller.clientWidth)
      if (!room) event.preventDefault()
    },
    { passive: false },
  )
  // Any scrolling at all, in the page, the panel or the card, puts the usage
  // details away: they belong to a button that has just moved.
  document.addEventListener(
    'scroll',
    (event) => {
      if (usageTip && !usageTip.contains(event.target)) closeUsage()
    },
    true,
  )
  new ResizeObserver(() => {
    placeMarks()
    placeCard()
  }).observe(deps.content())
  return { configure, setChats, open, togglePanel, event }
}
