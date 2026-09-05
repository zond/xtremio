# Which addons are worth keeping

The record Xtremio keeps of how each installed addon has been answering,
and the verdict the Installed tab reads off it. The rule itself is
`lib/features/addons/addon_health.dart`.

A profile collects addons. Some of them die quietly — the host goes away, a
debrid key expires, a catalog 404s — and nothing in a Stremio client tells
you which. Xtremio keeps a small record of **how each installed addon has
been answering**, and the Installed tab reads a verdict off it, so the
question "which of these can I uninstall?" has an answer that is not a
guess.

**Three outcomes, never two.** Every settled answer is counted as *answered
with content*, *answered with nothing*, or *failed*. Empty is its own
bucket and that is the whole point: a public-domain catalog legitimately
has nothing for this year's blockbuster, and folding that into "failed"
turns a specialist into a broken addon. The counts are kept per addon *and*
per resource kind (`catalog`, `meta`, `stream`, `subtitles`, only the ones
the manifest declares), so an addon with good streams and a dead catalog
reads as exactly that.

**What is counted, and by whom.** The Rust side counts and the app judges.
`rust/src/addon_observer.rs` watches the runtime's event pump, so every
board row, search, discover page, details load and subtitle list is
observed with no per-screen opt-in; `rust/src/addon_health.rs` holds the
counts and writes them to the preferences file at most once a minute (and
on shutdown). `lib/features/addons/addon_health.dart` holds the rule, as
one pure function over an immutable record, tested against a table of
cases. Changing the rule therefore changes no stored data.

**The verdicts**, in the order they are decided:

| Verdict | When |
| --- | --- |
| **Not used yet** | Fewer than 5 observations on every kind |
| **Often unreachable** | Some kind asked ≥ 5 times failed at least half of them, **and** the addon has answered nothing at all in over 7 days |
| **Never answered here** | All of that, and nothing it was ever asked came back: no answer with content, none with nothing in it, no time at which one did |
| **Rarely has anything** | Every declared kind was asked ≥ 20 times and carried content in under 5% of them |
| **Working · streams 34%** | Anything else, with how often the kind it is asked for most actually had something |

Both halves of *unreachable* are required. The ratio alone condemns an
addon that is failing right now but worked an hour ago — that is the
network, not the addon — and the silence alone condemns one that is simply
rarely asked. *Never answered here* is decided inside that verdict's own
branch rather than beside it, so it always rests on at least as much
evidence: an addon can only be called it once it could have been called
unreachable, and a handful of failures on something installed yesterday is
stopped by the same five-observation guard. It is the one verdict that
settles the question without a judgement call — an addon that has never
once worked here is nothing this device is getting anything from — which
is why it sorts above the rest. An empty answer still counts as an answer,
because it is one: that addon replied and had nothing, which is *rarely has
anything* and not this. And the label says **here** because that is the
whole of what was measured — requests this device made, over the life of a
record that begins when the addon was installed. An addon the rest of the
world reaches perfectly well looks identical from a network that cannot
get to it, so the evidence behind the chip says so in as many words.

*Rarely has anything* needs **every** declared kind to be answering
nothing, so one live resource rescues an addon, and a declared kind
nothing has asked for yet keeps the verdict off entirely. Five percent is
deliberately far below what a catalog addon manages: a stream specialist
that answers one title in twenty is working as intended.

**Counts decay rather than accumulate**: every count halves every 14 days,
one multiply on read and write, so the record is constant-sized and
self-healing — an addon that was broken for a week in March is not still
being argued with in June. Two timestamps ride along, because no decayed
float can say "it last worked three days ago". Tapping a verdict shows all
of it: when the addon last worked, and the three counts for every kind it
declares, with a kind nothing has asked for reading *not asked yet* — the
pump only sees what a screen actually requested, which is also why "not
used yet" is a first-class verdict and not a placeholder. A chevron on the
chip is what says the verdict can be opened, since three words and a
coloured dot read as a label; and on a television the chip is drawn under
its tile rather than inside it, because a tile takes focus as a whole and
a control inside one is reachable by nobody.

**A broken network is charged to nobody.** The addons on a board are asked
together and, with no connection, they fail together. One field's worth of
settled answers is held back as a *sweep* and committed only if at least
one addon in it did not fail; a sweep in which everything failed changes no
count at all. No reachability probe and no DHT dependency — just the
observation that a result where nothing worked is a result about the
connection. When *nothing* has answered since the app started, the Installed
tab says so in a banner, which is exactly when a list of freshly-failed
addons is most tempting to act on.

**What it never does.** It never records against the embedded server or the
profile's local addon, and it never labels a protected addon — two separate
rules, so a bad server release cannot put a verdict on Cinemeta. It adds no
way to remove an addon: Uninstall is the same menu item it always was,
absent for a protected addon and disabled while the profile is locked,
because a wrong verdict that silently removed a working addon would be
unrecoverable. "Forget this addon's history" drops one addon's record for
when the verdict is wrong — typically right after a debrid key was
replaced, where the old key's failures describe a configuration that no
longer exists. Nothing about health is synced to the account: it measures
*this device's* network.

**What is stored** is a single `addonHealth` key in the preferences file,
under `host[:port]#<12 hex of sha256(transport URL)>`. The URL itself is
never written down — a manifest URL can carry a debrid API key — and
neither is any query string, the resource id (that would be a viewing
history), a per-request timestamp, or an error message (a transport error
can carry the URL back in its own text). The app derives the same key by
hashing the transport URL it already holds, so the URL never leaves the
profile. At most 200 addons are remembered, and an addon the profile has
not had for 30 days is dropped at start-up.

Deliberately not built: latency or "slow" verdicts (a hang becomes a
failure at the 60-second client timeout, and nothing else is claimed), any
event log or per-title history, an active prober (traffic nobody asked for,
and it tests the manifest rather than the resource), and auto-uninstall or
auto-disable — the whole ask was to *decide*.
