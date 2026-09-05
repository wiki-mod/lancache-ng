# Auftrag: AG-CODE-012 Kommentarbereinigung

## Ziel

Du bist ausschließlich mit der Bereinigung von Code Kommentaren nach
`AG-CODE-012` beauftragt.

Die bestehende Codebasis ist der Prüfbereich.

Deine Änderungsbefugnis ist strikt auf Kommentare beschränkt.

Du darfst keinen produktiven Code, keine Logik, keine Konfiguration,
keine Datenstrukturen und kein Laufzeitverhalten verändern.

## Verbindliche Quellen

Vor jeder Arbeit MUSST du vollständig lesen:

1. `AGENTS.md` aus dem aktuellen Stand von `current_dev`
2. `.github/agent-dispatch-checklist.md` aus `current_dev`

`AGENTS.md` ist vollständig anzuwenden.

Insbesondere MUSST du `AG-CODE-012` im aktuell gültigen Wortlaut
anwenden und darfst die Regel nicht aus Erinnerung rekonstruieren.

Die aktuelle Version von `current_dev` ist maßgeblich.

## Pflichtblock für Dispatch

Vor Versand dieses Auftrags MUSS der Dispatcher an dieser Stelle den
vollständigen aktuellen Inhalt von

`.github/agent-dispatch-checklist.md`

aus `current_dev` unverändert einfügen.

Die Checkliste darf NICHT zusammengefasst, verkürzt, umformuliert oder
durch eine eigene Interpretation ersetzt werden.

<PASTE CURRENT agent-dispatch-checklist.md VERBATIM HERE>

## Für den Dispatcher: Haiku ist ein schwaches Modell, Pflicht-Nachkontrolle

Haiku ist ein deutlich schwächeres, rein mechanisches Modell, kein
billiger Sonnet-Ersatz.

Beauftrage Haiku nur mit engen, eindeutigen Teilaufträgen ohne
Interpretationsspielraum.

Bei Mehrdeutigkeit lieber weiter zerteilen als Spielraum lassen.

Haiku-Selbstberichte sind NICHT vertrauenswürdig. Der Dispatcher MUSS
jede "fertig"-Behauptung real gegenkontrollieren, nicht übernehmen:

1. Grep nach verbliebenen Kommentaren über dem Zeichenlimit, außerhalb
   erlaubter Ausnahmen wie Section-Divider oder eingebettete Daten.
2. Verifiziere, dass KEINE Nicht-Kommentar-Zeile geändert wurde: der
   resolved-config beziehungsweise Build muss unverändert bleiben
   (echter Paritätsbeweis), nicht nur der Datei-Diff optisch.
3. Prüfe jede `From:`-Referenz auf erfundene oder falsche Issue/PR.

Nach JEDER Haiku-Runde MUSST du zusätzlich `git log` und `git status`
auf UNERWARTETE Commits prüfen.

Haiku hat eine explizite "nicht committen / nicht pushen"-Anweisung
bereits ignoriert und trotzdem committed, einmal sogar gepusht, und
dabei acht Format-Verstöße plus eine falsche PR-Referenz hinterlassen,
obwohl es "fertig" meldete.

Eine "fertig, nicht committed"-Selbstauskunft von Haiku ersetzt diese
Nachkontrolle NICHT.

Paritäts- und Build-Verifikation laufen im verifizierten build-tools-
Container, nicht lokal angenommen.

## Erlaubter Änderungsbereich

Du DARFST ausschließlich syntaktisch echte Code Kommentare bearbeiten.

Dazu gehören nur Konstrukte, die die jeweilige Sprache tatsächlich als
Kommentar behandelt.

Beispiele sind:

`#`
`//`
`/* ... */`
`<!-- ... -->`

wenn diese an der jeweiligen Stelle tatsächlich Kommentare darstellen.

Du DARFST vorhandene Kommentarblöcke ersetzen oder zusammenführen.

Du DARFST einen fehlenden Kommentar nur ergänzen, wenn eine anwendbare
Regel aus `AGENTS.md` diesen Kommentar ausdrücklich verlangt.

## Strikt verboten

Du DARFST NICHT:

* produktiven Code verändern
* Programmlogik verändern
* Bedingungen verändern
* Variablen verändern
* Funktionsaufrufe verändern
* Befehle verändern
* Konfigurationswerte verändern
* Strings verändern
* Heredocs verändern
* Ausgaben oder Meldungen verändern
* Daten oder Fixtures verändern
* Dateien umformatieren
* reine Whitespace Änderungen außerhalb von Kommentaren durchführen
* neue Dateien anlegen
* bestehende Dateien löschen
* Dateien umbenennen
* Code verschieben
* Kommentare in Code umwandeln
* Code in Kommentare umwandeln
* Skripte erstellen
* Skripte zur Bearbeitung verwenden
* eigene Hilfsprogramme zur Bearbeitung erstellen
* automatisierte Massenersetzungen durchführen
* Kommentare blind abschneiden
* Text lediglich auf 60 Zeichen kürzen
* Informationen erfinden
* Issue oder PR Referenzen raten
* historische Referenzen ansammeln

Wenn eine notwendige Korrektur produktiven Code berühren würde,
MUSST du stoppen und an den Coordinator eskalieren.

Du darfst diese Grenze nicht selbst erweitern.

## Keine Skriptbearbeitung

Skripte und automatisierte Transformationsprogramme sind für diese
Aufgabe verboten.

Kommentarblöcke müssen semantisch einzeln beurteilt werden.

Eine mechanische Kürzung anhand von Zeichenanzahl ist ausdrücklich
verboten.

Eine Ersetzung ist nur zulässig, nachdem du verstanden hast:

1. was der zugehörige Code aktuell tut
2. warum der Kommentar an dieser Stelle erforderlich ist
3. welche Aussage nach aktuellem Codezustand sachlich korrekt ist
4. welche Referenz für die aktuelle Version tatsächlich gilt

## AG-CODE-012 Zielformat

Jeder bearbeitete Kommentar MUSS sober, dry und ausschließlich auf den
aktuellen Zustand bezogen sein.

Zulässig ist genau ein Block pro Code Stelle:

```text
What: <current behavior>
Why: <actual reason>
From: Issue #N | PR #N
```

Wenn keine gültige Referenz bekannt und verifiziert ist:

```text
What: <current behavior>
Why: <actual reason>
```

`From:` darf niemals erfunden werden.

## What

`What:` ist verpflichtend.

Es MUSS genau eine physische Zeile sein.

Die vollständige Zeile inklusive `What:` und Leerzeichen darf maximal
60 Zeichen enthalten.

60 Zeichen sind KEIN Zielwert.

Kürzer ist ausdrücklich vorzuziehen, wenn die Aussage vollständig und
präzise bleibt.

`What:` beschreibt ausschließlich, was der aktuelle Code tatsächlich
macht.

Es darf keine Historie oder Änderungsgeschichte enthalten.

## Why

`Why:` ist verpflichtend.

Es MUSS genau eine physische Zeile sein.

Die vollständige Zeile inklusive `Why:` und Leerzeichen darf maximal
60 Zeichen enthalten.

60 Zeichen sind KEIN Zielwert.

Kürzer ist ausdrücklich vorzuziehen, wenn die tatsächliche Begründung
erhalten bleibt.

`Why:` MUSS den realen nicht offensichtlichen Grund nennen.

Zulässige Inhalte sind beispielsweise:

* Constraint
* Invariant
* Sicherheitsgrund
* Workaround
* technische Anforderung
* nicht offensichtliche Nebenwirkung

`Why:` darf nicht einfach `What:` mit anderen Worten wiederholen.

## From

`From:` ist nur zulässig, wenn die Referenz tatsächlich verifiziert
wurde.

Die Zeile darf maximal eine Issue und eine PR Referenz enthalten.

Sie darf keinerlei Erklärung enthalten.

Zulässige Formen sind ausschließlich:

```text
From: Issue #123
From: PR #456
From: Issue #123 | PR #456
```

Die Referenz MUSS zur aktuellen Version des kommentierten Codes gehören.

Historische oder ersetzte Referenzen dürfen nicht gesammelt werden.

Wenn eine Referenz nicht sicher feststellbar ist, darf sie nicht geraten
werden.

Nutze bei Bedarf die vorhandene Git Historie sowie Issue und PR Historie
zur Verifikation.

## Sober and Dry

Der Kommentar MUSS ausschließlich den aktuellen Zustand dokumentieren.

Nicht zulässig sind insbesondere:

* Storytelling
* Untersuchungsgeschichte
* Review Geschichte
* Änderungsgeschichte
* zeitliche Abläufe
* frühere Implementierungen
* aufgegebene Ansätze
* Begründungen des Bearbeitungsprozesses
* Aussagen darüber, was vorher falsch war
* Aussagen darüber, was gerade repariert wurde
* Aussagen darüber, wie etwas festgestellt wurde
* Test oder Verifikationsnarrative

Der Kommentar ist Dokumentation des aktuellen Codes und kein
Arbeitsprotokoll.

## Keine blinde Kürzung

Ein bestehender Kommentar darf NICHT einfach abgeschnitten werden, bis
er unter das Zeichenlimit passt.

Du MUSST zuerst seine fachliche Aussage bestimmen.

Danach MUSST du diese Aussage neu und möglichst knapp formulieren.

Wenn relevante historische oder investigative Informationen nicht in
das zulässige Format gehören, dürfen sie nicht durch längere Kommentare,
Fortsetzungszeilen oder zusätzliche Kommentarblöcke erhalten werden.

Sie gehören in den dafür vorgesehenen dauerhaften Arbeitsnachweis.

## Ein Block pro Stelle

Eine Code Stelle darf genau einen zugehörigen
`What:` / `Why:` / `From:` Block besitzen.

Du DARFST NICHT mehrere Blöcke stapeln, um das Zeichenlimit zu umgehen.

Du DARFST NICHT:

```text
What: ...
What: ...
Why: ...
Why: ...
```

verwenden.

Du DARFST ebenfalls keine Fortsetzungszeilen erzeugen.

## Semantische Prüfung

Vor jeder Änderung MUSST du den unmittelbar zugehörigen Code lesen.

Du darfst einen Kommentar nur ändern, wenn seine neue Aussage durch den
vorhandenen Code belegt ist.

Wenn du die Bedeutung des Codes nicht sicher bestimmen kannst:

STOP.

Nicht raten.

Nicht vereinfachen.

Nicht löschen.

Nicht blind umformulieren.

Melde die konkrete Stelle an den Coordinator.

## Bestehende korrekte Kommentare

Ein bereits regelkonformer Kommentar MUSS nicht künstlich verändert
werden.

Insbesondere darf ein kurzer korrekter Kommentar nicht verlängert
werden, nur um näher an 60 Zeichen zu kommen.

Minimale, präzise Formulierungen sind erwünscht.

## Änderungsdisziplin

Vor jeder Datei MUSST du ihren Inhalt lesen.

Nach der Bearbeitung MUSST du den Diff der Datei prüfen.

Im Diff dürfen ausschließlich Kommentaränderungen erscheinen.

Sobald eine Änderung außerhalb eines Kommentars erscheint:

STOP.

Setze die unbeabsichtigte Änderung zurück.

Fahre erst fort, wenn der Diff wieder ausschließlich Kommentare enthält.

## Keine Nebenarbeiten

Diese Aufgabe autorisiert keine opportunistischen Verbesserungen.
-> Literally DISACK
Auch wenn du während der Arbeit andere Probleme findest, darfst du
produktiven Code nicht verändern.
-> Hinweis an den Koordinator oder Main, jenach dem  wer dein Vorgesetzer ist.

Probleme außerhalb des erlaubten Kommentarbereichs MUSST du melden,
aber nicht selbst beheben.
-> Hinweis an den Koordinator oder Main, jenach dem  wer dein Vorgesetzer ist.

Eine Regel aus `AGENTS.md` darf nicht als Begründung verwendet werden,
um diese explizite Änderungsgrenze eigenständig auf produktiven Code zu
erweitern.
-Literally DISACK

Bei einem Konflikt MUSST melden UND die arbeit bis zur klärung EINSTELLEN.
-> Hinweis an den Koordinator oder Main, jenach dem  wer dein Vorgesetzer ist.
-> Du Solltest du eine andere DAtei haben, an der du Fortsetzen kannst, dann arbeite an dieser weiter, jedoch darfst du die ein Konflikt hat bis zur klärung NICHT weiter bearbeiten.

## Abschlussprüfung

Vor Beginn MUSST du bestätigen:

* aktuelle `AGENTS.md` aus `current_dev` vollständig gelesen UND verstanden zu haben.
* aktuelle Dispatch Checkliste vollständig gelesen und akzeptiert
* `AG-CODE-012` anhand des aktuellen Wortlauts geprüft
* ausschließlich Kommentare verändert
* keine produktive Logik verändert
* keine Skripte erstellt oder zur Transformation verwendet
* keine blinde Kürzung durchgeführt
* jede geänderte Aussage gegen den zugehörigen Code geprüft
* `What:` maximal 60 Zeichen
* `Why:` maximal 60 Zeichen
* 60 Zeichen nicht als Zielwert behandelt
* `From:` nur mit verifizierten Referenzen verwendet
* keine gestapelten Kommentarblöcke erzeugt
* keine Fortsetzungszeilen erzeugt
* finalen Diff vollständig geprüft

Wenn auch nur ein Punkt nicht bestätigt werden kann, darf die Aufgabe
nicht als abgeschlossen gemeldet werden.

## Abschlussbericht

Der Abschlussbericht MUSS knapp bleiben.

Berichte ausschließlich:

1. welche Dateien geprüft wurden
2. welche Dateien Kommentaränderungen erhielten
3. Anzahl geänderter Kommentarblöcke
4. ob ausschließlich Kommentare verändert wurden
5. ob alle Zeichenlimits geprüft wurden
6. ob ungeklärte Stellen verbleiben

DISACK: Keine zusätzliche Implementierungsarbeit durchführen.

Agent Dispatch Checklist
This file is the fixed, mandatory minimum standard baseline for every Agent()/SendMessage()/Workflow agent() call in this repository — both an initial dispatch and every later continuation message to an already-running or paused agent, always, regardless of reason. A specific dispatch may always add more or stricter requirements on top of this list — it may never satisfy less than what is listed here. It exists because relying on the dispatcher to recall the relevant subset of AGENTS.md from memory, per task, has repeatedly failed in practice (see AG-WF-035's own incident note). This file turns that recall problem into a fixed list to paste and check off, not a thing to remember.

How to use this file: Paste this entire checklist verbatim into every dispatch/continuation prompt. If any item is deliberately omitted for a specific dispatch, the prompt must say so explicitly and state why — a silent omission is a compliance gap, not a judgment call the dispatcher gets to make invisibly.

Do
Governance read, every dispatch, every continuation. (AG-GOV-001)
Explicit-by-name acceptance report, spot-checked by asking for a quoted rule ID. This report must also remind the coordinator to send back this agent's own task/session ID (via SendMessage, or whichever equivalent applies) — an agent cannot determine that ID on its own, so it must be relayed before the marker commit in item 5 below can include it.
Worktree binding, named and absolute, verified before every commit via git rev-parse --show-toplevel/git branch --show-current. (AG-WF-002, AG-WF-024)
Rebase-first onto the current base before any work begins — AND re-verify the rebase is still current immediately before declaring the task finished, not only at the start. (AG-WF-002)
Empty marker commit, first action, before any code change. The commit message must state the task/issue binding, that this checklist was read and accepted, AND your own task/session ID — the confirmation lives as a durable, git-anchored artifact tied to the worktree, not only as a chat statement, and must remain reachable/resumable independent of worktree naming or surviving chat history. (AG-WF-002, AG-WF-017)
Language split, stated explicitly: prose/reports German, GitHub content English. This applies to the dispatch prompt's own instructional prose too, not only to the agent's output — pasting this checklist (English, quoted verbatim per its own instruction above) does not license writing the surrounding task description in English; only literal quoted material (code, log output, file paths, commit messages, GitHub content) stays English. (AG-CC-002/003, AG-GH-001)
CLD-<unixtime> identity marker on every GitHub-visible write, and on every marker commit — obtained fresh via date +%s at write time, never invented/estimated. (AG-WF-017)
WIP cadence: within 15 min, then every 15 min, real timestamp comparison. (AG-GH-013)
Check for existing coverage before starting new branch/investigation work. (AG-GH-017)
Read full chronological history before acting on any issue/PR. (AG-GH-019)
Push/PR authorization boundary, stated explicitly per dispatch.
--admin/bypass boundary: literal PR-scoped "ACK" via the structured question. (AG-WF-039)
Durable persistence before declaring done. (AG-WF-026)
Before declaring "I think I am done": call advisor and check the ENTIRE PR/diff — every file it touches — against AGENTS.md as a whole, not just the task's own narrow focus. Advisor must not stop at the first finding; it must enumerate ALL violations found. Re-verify the branch is still rebased onto current base (see item 4) before the completion report. Most real problems in this project trace back to an AGENTS.md violation somewhere in the touched files — treat the whole PR as the unit of review, not only the lines changed for the stated task. (AG-WF-035, AG-WF-033, AG-WF-011)
Treat prior results as stale until reverified. (AG-WF-021)
Poll intervals ≥300s, with no exception, ever — a poll faster than 300s counts as a DISACK-equivalent violation at any moment it occurs. (AG-CI-020)
Remove the worktree once finished (pushed/PR opened, or explicitly told to stop) — a leftover worktree becomes the next agent's recycled-slot collision otherwise. (AG-WF-002)
Apply AGENTS.md in full — no shortcuts, no cherry-picking only the parts that seem relevant to the immediate task.
Prefer native local commands over an API call at any time, instead and/or before an API call — use the API when there is no local equivalent. (AG-VAL-005)
New file = formal DISACK by default. Before creating any new script, library, or test-suite file, complete the required search: does an existing file already own the same conceptual class/responsibility (extend it), or do related sibling files already exist that should be consolidated instead? State the result of this check in the PR. The DISACK lifts only by extending an existing file, or by a documented check plus an explicit maintainer/coordinator ACK obtained before the file is created. (AG-CODE-013)
Ground every factual claim in evidence actually obtained — a file actually read, a command actually run, an output actually observed. State what was checked, not just the conclusion. A statement's strength must never exceed the evidence behind it: label anything unverified as such ("not verified"/"not tested") instead of presenting a plausible guess as fact. (AG-INT-001)
Don't
Not allowed to spawn own sub-agents unless the task explicitly authorizes coordinating them — flagged: not yet backed by a numbered AGENTS.md rule.
A pause/stop is lifted only by a fresh literal "ACK." (AG-WF-038)
Never a mutating git command against the shared main checkout, under any circumstance. Never lie, invent, or attempt to misrepresent what happened. If unsure, stop and ask the coordinator for verification/clarification — do not continue until that clarification is satisfied. (AG-INT-001)
Never trust a recycled or unfamiliar worktree as clean without verifying it first. If it's not what you were told to expect, stop and clarify with your coordinator before doing any work in it. (AG-WF-024)
Never declare multi-item work "complete" from memory — recount against the full list.
Never downgrade a verification requirement to "stichprobenartig" without explicit authorization.
Fix a found defect in the same pass, don't defer to a comment. (AG-WF-027)
Treat a found bug as a failure class, search the rest of the codebase for the same pattern. (AG-WF-011, AG-CI-015)
Never work or commit in an unverified/unknown worktree. Before committing, confirm the worktree actually exists and matches what you were told — if unsure, ask your coordinator and do not proceed without an answer.
Never let an English quoted artifact (this checklist, a code snippet, a log excerpt) justify writing your own surrounding instructional prose in English. (AG-CC-003)
Never create a new file because it is more convenient than reading/extending an existing one, and never create the file first and ask for the ACK afterward. A plausible-sounding reason for a new file is not itself an ACK. If genuinely uncertain whether an existing file should be extended instead, stop and ask the coordinator — do not create the file while that is unresolved. (AG-CODE-013)
Never suppress, filter, downgrade, or hide a real warning/error/failure signal to make a check appear to pass (|| true, redirecting stderr, excluding a failing target from scope, relabeling a failure as expected/skipped, retrying silently until green, etc.). A check that genuinely doesn't apply gets an explicit SKIP/NOT-RUN with a stated reason — never execute-and-discard. (AG-INT-002)
[AG-LAW-001] AGENTS.md is a single, unified rulebook: all applicable rules apply simultaneously to the entire affected change, not only the rule that motivated it. A task is not complete until the entire affected file and the complete change have been checked against every applicable rule — checking only some applicable rules and then declaring the task done is itself a violation of AG-LAW-001. "You touched it, you fix it" (Rule-Ref: AG-WF-027, not AG-CODE-008 — that one is comment-specific) applies to the entire affected file: known violations found along the way must be fixed within the same piece of work, not deferred to a follow-up comment. Shortcuts and deferral are not allowed. Any uncertainty about how to proceed must be escalated up the dispatch chain to the main thread (Rule-Ref: AG-WF-002's escalation clause), which resolves it directly or obtains a decision.
