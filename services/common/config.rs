//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// What: settings from SOT schema, defaults, file, env.
// Why: every crate reads values through one checked set.
// From: Issue #1683 | PR #1980

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::{Path, PathBuf};

// What: env key of the baked default rows.
// Why: the SOT bakes defaults into each image.
// From: Issue #1683 | PR #1980
pub const DEFAULTS_KEY: &str = "LANCACHE_RUNTIME_DEFAULTS";

// What: env key of the baked schema rows.
// Why: kind, range, effect and owner per key.
// From: Issue #1683 | PR #1980
pub const SCHEMA_KEY: &str = "LANCACHE_RUNTIME_SCHEMA";

// What: separator of baked rows.
// Why: the SOT joins rows with a pipe.
// From: Issue #1683 | PR #1980
const ROW_SEP: char = '|';

// What: type of a value.
// Why: the schema kind decides parsing and the ui field.
// From: Issue #1683 | PR #1980
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Kind {
    Text,
    Bool,
    Uint { min: u64, max: u64, clamp: bool },
    List,
    Path,
    Secret,
    Choice(Vec<String>),
}

// What: what a change needs before it is live.
// Why: only affected programs act on a change.
// From: Issue #1683 | PR #1980
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Effect {
    Live,
    Reload,
    Restart,
    Container,
    Recreate,
}

// What: one schema row.
// Why: the ui builds fields and the runner plans from it.
// From: Issue #1683 | PR #1980
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Spec {
    pub key: String,
    pub kind: Kind,
    pub required: bool,
    pub effect: Effect,
    pub owner: String,
}

// What: a checked value.
// Why: callers never parse raw text again.
// From: Issue #1683 | PR #1980
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Value {
    Text(String),
    Bool(bool),
    Uint(u64),
    List(Vec<String>),
}

impl fmt::Display for Value {
    // What: canonical text of a value.
    // Why: revision and diff compare this text.
    // From: Issue #1683 | PR #1980
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Text(v) => f.write_str(v),
            Self::Bool(v) => write!(f, "{v}"),
            Self::Uint(v) => write!(f, "{v}"),
            Self::List(v) => f.write_str(&v.join(" ")),
        }
    }
}

// What: items of a list value.
// Why: the SOT allows comma and blank as separators.
// From: Issue #1683 | PR #1980
pub fn list_items(raw: &str) -> impl Iterator<Item = &str> {
    raw.split(|c: char| c == ',' || c.is_whitespace())
        .filter(|item| !item.is_empty())
}

// What: the rows of a text without blanks and # rows.
// Why: list files hold comments and empty lines.
// From: Issue #1683 | PR #2017
pub fn data_rows(text: &str) -> impl Iterator<Item = &str> {
    text.lines()
        .map(str::trim)
        .filter(|row| !row.is_empty() && !row.starts_with('#'))
}

// What: order of texts: longer first, then descending.
// Why: a longer number is newer, a longer suffix closer.
// From: Issue #1683 | PR #2017
pub fn longest_first(a: &str, b: &str) -> std::cmp::Ordering {
    b.len().cmp(&a.len()).then_with(|| b.cmp(a))
}

// What: adds an item unless the list has it.
// Why: lists keep first-seen order without doubles.
// From: Issue #1683 | PR #1980
pub fn add_once(list: &mut Vec<String>, item: &str) {
    if !list.iter().any(|n| n == item) {
        list.push(item.to_string());
    }
}

// What: not empty; only ASCII letters, digits and extra.
// Why: such a value cannot leave its place in a config.
// From: Issue #1683 | PR #2017
pub fn is_plain(text: &str, extra: &str) -> bool {
    !text.is_empty()
        && text
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || extra.contains(c))
}

// What: a bool from its usual words.
// Why: env and forms send true/false, 1/0, yes/no, on/off.
// From: Issue #1683 | PR #1858
pub fn parse_bool(raw: &str) -> Option<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" | "on" => Some(true),
        "false" | "0" | "no" | "off" => Some(false),
        _ => None,
    }
}

// What: a plain decimal number, digits only.
// Why: "+5" or " 5" in a setting is a typo.
// From: Issue #1683 | PR #1980
fn parse_uint(raw: &str) -> Option<u64> {
    if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    raw.parse().ok()
}

impl Effect {
    // What: effect from its SOT word.
    // Why: an unknown word is an error, never Live.
    // From: Issue #1683 | PR #1980
    fn parse(word: &str) -> Result<Self, String> {
        match word {
            "live" => Ok(Self::Live),
            "reload" => Ok(Self::Reload),
            "restart" => Ok(Self::Restart),
            "container" => Ok(Self::Container),
            "recreate" => Ok(Self::Recreate),
            other => Err(format!("unknown effect {other:?}")),
        }
    }
}

impl Spec {
    // What: true for a row of kind secret.
    // Why: one owner of the test; pages hide such values.
    // From: Issue #1683 | PR #2017
    pub fn is_secret(&self) -> bool {
        matches!(self.kind, Kind::Secret)
    }

    // What: parse KEY=kind;min;max;effect;owner.
    // Why: the SOT schema row format.
    // From: Issue #1683 | PR #1980
    fn parse(row: &str) -> Result<Self, String> {
        let (key, rest) = row
            .split_once('=')
            .ok_or_else(|| format!("schema row {row:?} has no ="))?;
        let fields: Vec<&str> = rest.split(';').collect();
        let [kind, min, max, effect, owner] = fields[..] else {
            return Err(format!("schema row {row:?} needs 5 fields"));
        };
        let (kind, required) = match kind.strip_suffix('?') {
            Some(k) => (k, false),
            None => (kind, true),
        };
        let bound = |word: &str, fallback: u64| -> Result<u64, String> {
            if word.is_empty() {
                return Ok(fallback);
            }
            parse_uint(word).ok_or_else(|| format!("{key}: bound {word:?} is no number"))
        };
        let kind = match kind {
            "text" => Kind::Text,
            "bool" => Kind::Bool,
            "uint" | "uint~" => Kind::Uint {
                min: bound(min, 0)?,
                max: bound(max, u64::MAX)?,
                clamp: kind == "uint~",
            },
            "list" => Kind::List,
            "path" => Kind::Path,
            "secret" => Kind::Secret,
            "choice" => Kind::Choice(min.split(',').map(str::to_string).collect()),
            other => return Err(format!("{key}: unknown kind {other:?}")),
        };
        Ok(Self {
            key: key.to_string(),
            kind,
            required,
            effect: Effect::parse(effect).map_err(|e| format!("{key}: {e}"))?,
            owner: owner.to_string(),
        })
    }

    // What: check raw text against this spec.
    // Why: one check for env, file, defaults and forms.
    // From: Issue #1683 | PR #1980
    fn check(&self, raw: &str) -> Result<(Value, Option<String>), String> {
        let key = &self.key;
        match &self.kind {
            Kind::Text | Kind::Secret => Ok((Value::Text(raw.to_string()), None)),
            Kind::Path => {
                if Path::new(raw).is_absolute() {
                    Ok((Value::Text(raw.to_string()), None))
                } else {
                    Err(format!("{key}: path {raw:?} is not absolute"))
                }
            }
            Kind::Bool => parse_bool(raw)
                .map(|b| (Value::Bool(b), None))
                .ok_or_else(|| format!("{key}: {raw:?} is no bool")),
            Kind::List => Ok((
                Value::List(list_items(raw).map(str::to_string).collect()),
                None,
            )),
            Kind::Choice(words) => {
                if words.iter().any(|w| w == raw) {
                    Ok((Value::Text(raw.to_string()), None))
                } else {
                    Err(format!("{key}: {raw:?} is not one of {}", words.join(", ")))
                }
            }
            Kind::Uint { min, max, clamp } => {
                let n = parse_uint(raw).ok_or_else(|| format!("{key}: {raw:?} is no number"))?;
                if (*min..=*max).contains(&n) {
                    return Ok((Value::Uint(n), None));
                }
                if !clamp {
                    return Err(format!("{key}: {n} is outside {min}..={max}"));
                }
                let fixed = n.clamp(*min, *max);
                Ok((
                    Value::Uint(fixed),
                    Some(format!("{key}: {n} clamped to {fixed}")),
                ))
            }
        }
    }
}

// What: non-empty rows of a baked list.
// Why: an empty row is no entry.
// From: Issue #1683 | PR #1980
fn baked_rows(baked: &str) -> impl Iterator<Item = &str> {
    baked
        .split(ROW_SEP)
        .map(str::trim)
        .filter(|r| !r.is_empty())
}

// What: the env value of a key; empty counts as unset.
// Why: Compose passes KEY= for a key nobody set.
// From: Issue #1683 | PR #2017
pub fn env_set(env: &dyn Fn(&str) -> Option<String>, key: &str) -> Option<String> {
    env(key).filter(|v| !v.is_empty())
}

// What: file, else env, else default; fills @KEY@.
// Why: KEY= in the file means default; env is a stale copy.
// From: Issue #1683 | PR #2017
fn effective(
    key: &str,
    file: &BTreeMap<String, String>,
    env: &dyn Fn(&str) -> Option<String>,
    defaults: &BTreeMap<&str, &str>,
    depth: u8,
) -> Result<Option<String>, String> {
    match file.get(key) {
        Some(v) if !v.is_empty() => return Ok(Some(v.clone())),
        Some(_) => {}
        None => {
            if let Some(v) = env_set(env, key) {
                return Ok(Some(v));
            }
        }
    }
    match defaults.get(key).filter(|v| !v.is_empty()) {
        Some(v) => expand_default(v, file, env, defaults, depth).map(Some),
        None => Ok(None),
    }
}

// What: each @KEY@ of a default replaced by its value.
// Why: the SOT names other keys; the image bakes them raw.
// From: Issue #1683 | PR #2017
fn expand_default(
    value: &str,
    file: &BTreeMap<String, String>,
    env: &dyn Fn(&str) -> Option<String>,
    defaults: &BTreeMap<&str, &str>,
    depth: u8,
) -> Result<String, String> {
    if depth > 16 {
        return Err(format!("default {value:?}: @KEY@ refers to itself"));
    }
    let key_char = |b: &u8| b.is_ascii_uppercase() || b.is_ascii_digit() || *b == b'_';
    let mut out = String::new();
    let mut rest = value;
    while let Some(at) = rest.find('@') {
        out.push_str(&rest[..at]);
        let after = &rest[at + 1..];
        let len = after.bytes().take_while(key_char).count();
        if len > 0 && after[len..].starts_with('@') {
            let name = &after[..len];
            let got = effective(name, file, env, defaults, depth + 1)?
                .ok_or_else(|| format!("default {value:?} names @{name}@, which has no value"))?;
            out.push_str(&got);
            rest = &after[len + 1..];
        } else {
            out.push('@');
            rest = after;
        }
    }
    out.push_str(rest);
    Ok(out)
}

// What: key and value of a KEY=VALUE line; else None.
// Why: the stack .env holds What/Why/From comment lines.
// From: Issue #1683 | PR #2017
fn line_entry(line: &str) -> Option<(&str, &str)> {
    let (key, value) = line.split_once('=')?;
    let key = key.trim();
    (!key.is_empty() && !key.starts_with('#')).then_some((key, value.trim()))
}

// What: the text of the stack .env; missing is empty.
// Why: reading and writing see a new install alike.
// From: Issue #1683 | PR #2017
fn read_text(path: &Path) -> Result<String, String> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ok(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

// What: the raw KEY=VALUE lines of the stack .env.
// Why: a missing file means no values yet.
// From: Issue #1683 | PR #2017
pub fn read_raw(path: &Path) -> Result<BTreeMap<String, String>, String> {
    Ok(read_text(path)?
        .lines()
        .filter_map(line_entry)
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect())
}

// What: the values of the stack .env; "$" values left out.
// Why: setup.sh keeps ${VAR} that only Compose expands.
// From: Issue #1683 | PR #2017
pub fn read_file(path: &Path) -> Result<BTreeMap<String, String>, String> {
    let mut all = read_raw(path)?;
    // What: a key of <file>.local replaces the file's one.
    // Why: Compose reads it as the second env file.
    // From: Issue #1683 | PR #2017
    all.extend(read_raw(&override_path(path))?);
    all.retain(|_, v| !v.contains('$'));
    Ok(all)
}

// What: override file of the stack .env: <file>.local.
// Why: it wins for single keys, as fail2ban's .local.
// From: Issue #1683 | PR #2017
pub fn override_path(path: &Path) -> PathBuf {
    crate::fs::with_suffix(path, ".local")
}

// What: lock file of the stack .env: <file>.lock.
// Why: setup.sh flocks the same name before it writes.
// From: Issue #1683 | PR #2017
pub fn lock_path(path: &Path) -> PathBuf {
    crate::fs::with_suffix(path, ".lock")
}

// What: rejects what Compose would read differently.
// Why: same rule as validate_env_value of setup.sh.
// From: Issue #1683 | PR #2017
fn env_safe(key: &str, raw: &str) -> Result<(), String> {
    match raw
        .chars()
        .find(|c| matches!(c, '\n' | '\r' | '$' | '`' | '"' | '\'' | '\\' | '#'))
    {
        Some(c) => Err(format!("{key}: {c:?} is not allowed in the stack .env")),
        None => Ok(()),
    }
}

// What: checked values into the stack .env.
// Why: every ui change goes through one write path.
// From: Issue #1683 | PR #2017
pub fn store(
    path: &Path,
    current: &Settings,
    updates: &BTreeMap<String, String>,
) -> Result<(), String> {
    let over = override_path(path);
    let overridden = read_raw(&over)?;
    for (key, raw) in updates {
        env_safe(key, raw)?;
        // What: a key of <file>.local is refused here.
        // Why: its value wins; a save changes nothing.
        // From: Issue #1683 | PR #2017
        if overridden.contains_key(key) {
            return Err(format!(
                "{key}: set in {}, which wins; remove it there first",
                over.display()
            ));
        }
        // What: a container setting is refused here.
        // Why: in the .env the name is a Compose host path.
        // From: Issue #1683 | PR #2017
        if current
            .spec(key)
            .is_some_and(|s| s.effect == Effect::Container)
        {
            return Err(format!("{key}: a container setting; setup.sh sets it"));
        }
        if !raw.is_empty() {
            current.validate(key, raw)?;
        }
    }
    write_lines(path, updates)
}

// What: puts raw lines back as read_raw gave them.
// Why: a refused save restores even ${VAR} values.
// From: Issue #1683 | PR #2017
pub fn restore(path: &Path, values: &BTreeMap<String, String>) -> Result<(), String> {
    write_lines(path, values)
}

// What: sets KEY=VALUE lines in place under the lock.
// Why: one file; comments, order and other keys stay.
// From: Issue #1683 | PR #2017
fn write_lines(path: &Path, updates: &BTreeMap<String, String>) -> Result<(), String> {
    let lock = lock_path(path);
    let held = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lock)
        .map_err(|e| format!("{}: {e}", lock.display()))?;
    held.lock()
        .map_err(|e| format!("{}: {e}", lock.display()))?;
    let old = read_text(path)?;
    let mut done = BTreeSet::new();
    let mut body = String::new();
    for line in old.lines() {
        let key = line_entry(line).map(|(key, _)| key);
        match key.filter(|k| updates.contains_key(*k)) {
            Some(key) => {
                // What: a second line of it is dropped.
                // Why: Compose and setup.sh read one value.
                // From: Issue #1683 | PR #2017
                if done.insert(key.to_string()) {
                    body.push_str(&format!("{key}={}\n", updates[key]));
                }
            }
            None => {
                body.push_str(line);
                body.push('\n');
            }
        }
    }
    for (key, raw) in updates.iter().filter(|(k, _)| !done.contains(*k)) {
        body.push_str(&format!("{key}={raw}\n"));
    }
    if body == old {
        return Ok(());
    }
    crate::fs::write(
        path,
        body.as_bytes(),
        crate::fs::PRIVATE_MODE,
        crate::fs::Place::Replace,
        crate::fs::Owner::default(),
    )
    .map_err(|e| format!("{}: {e}", path.display()))
}

// What: the checked settings of one process.
// Why: one load at start; reload builds a new set.
// From: Issue #1683 | PR #1980
#[derive(Clone, Debug, Default)]
pub struct Settings {
    specs: BTreeMap<String, Spec>,
    values: BTreeMap<String, Value>,
    pub warnings: Vec<String>,
}

impl Settings {
    // What: load schema, then file > env > default.
    // Why: the file is the live .env; env is from start.
    // From: Issue #1683 | PR #2017
    pub fn load(
        env: &dyn Fn(&str) -> Option<String>,
        saved_file: Option<&Path>,
    ) -> Result<Self, String> {
        let schema = env(SCHEMA_KEY).ok_or_else(|| format!("{SCHEMA_KEY} is not set"))?;
        let baked = env(DEFAULTS_KEY).unwrap_or_default();
        let defaults: BTreeMap<&str, &str> = baked_rows(&baked)
            .filter_map(|r| r.split_once('='))
            .collect();
        let mut set = Self::default();
        let mut errors = Vec::new();
        let mut specs = Vec::new();
        for row in baked_rows(&schema) {
            match Spec::parse(row) {
                Ok(spec) => specs.push(spec),
                Err(e) => errors.push(e),
            }
        }
        let mut file = match saved_file {
            Some(path) => read_file(path)?,
            None => BTreeMap::new(),
        };
        // What: the file sets ui keys, not container ones.
        // Why: the .env has host paths under these names.
        // From: Issue #1683 | PR #2017
        let ui_keys: BTreeSet<&str> = specs
            .iter()
            .filter(|s| s.effect != Effect::Container)
            .map(|s| s.key.as_str())
            .collect();
        file.retain(|k, _| ui_keys.contains(k.as_str()));
        for spec in specs {
            let raw = match effective(&spec.key, &file, env, &defaults, 0) {
                Ok(raw) => raw,
                Err(e) => {
                    errors.push(e);
                    continue;
                }
            };
            match raw {
                Some(raw) => match spec.check(&raw) {
                    Ok((value, note)) => {
                        set.warnings.extend(note);
                        set.values.insert(spec.key.clone(), value);
                    }
                    Err(e) => errors.push(e),
                },
                None if spec.required => errors.push(format!("{} is not set", spec.key)),
                None => {}
            }
            set.specs.insert(spec.key.clone(), spec);
        }
        // What: SOT defaults without a schema row, as text.
        // Why: templates read fixed keys; env still wins.
        // From: Issue #1683 | PR #1980
        for (key, value) in &defaults {
            if set.specs.contains_key(*key) {
                continue;
            }
            let raw = match env_set(env, key) {
                Some(raw) => raw,
                None => match expand_default(value, &file, env, &defaults, 0) {
                    Ok(raw) => raw,
                    Err(e) => {
                        errors.push(e);
                        continue;
                    }
                },
            };
            if !raw.is_empty() {
                set.values.insert(key.to_string(), Value::Text(raw));
            }
        }
        if errors.is_empty() {
            Ok(set)
        } else {
            Err(errors.join("; "))
        }
    }

    // What: the schema row of one key.
    // Why: the ui needs kind and effect per field.
    // From: Issue #1683 | PR #1980
    pub fn spec(&self, key: &str) -> Option<&Spec> {
        self.specs.get(key)
    }

    // What: all schema rows in key order.
    // Why: the setup page lists every setting.
    // From: Issue #1683 | PR #1980
    pub fn specs(&self) -> impl Iterator<Item = &Spec> {
        self.specs.values()
    }

    // What: the checked value of one key.
    // Why: optional keys may have none.
    // From: Issue #1683 | PR #1980
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.values.get(key)
    }

    // What: all loaded values, secrets left out.
    // Why: templates show fixed SOT values as well.
    // From: Issue #1683 | PR #1980
    pub fn texts(&self) -> impl Iterator<Item = (&String, String)> {
        self.values
            .iter()
            .filter(|(k, _)| !self.specs.get(*k).is_some_and(Spec::is_secret))
            .map(|(k, v)| (k, v.to_string()))
    }

    // What: value as text; missing is an error.
    // Why: the error names the key.
    // From: Issue #1683 | PR #1980
    pub fn text(&self, key: &str) -> Result<String, String> {
        // What: a compose-only key falls back to the env.
        // Why: operator keys like IP_HTTPS have no SOT row.
        // From: Issue #1683 | PR #1980
        self.get(key)
            .map(Value::to_string)
            .or_else(|| env_set(&process_env, key))
            .ok_or_else(|| format!("{key} is not set"))
    }

    // What: value as text; empty when it is missing.
    // Why: pages and optional features read it unguarded.
    // From: Issue #1683 | PR #2017
    pub fn text_or_empty(&self, key: &str) -> String {
        self.text(key).unwrap_or_default()
    }

    // What: value as number.
    // Why: only uint keys answer; others are errors.
    // From: Issue #1683 | PR #1980
    pub fn uint(&self, key: &str) -> Result<u64, String> {
        match self.get(key) {
            Some(Value::Uint(n)) => Ok(*n),
            // What: a fixed SOT default is text; parse it.
            // Why: keys without schema row load as text.
            // From: Issue #1683 | PR #1980
            Some(Value::Text(t)) => parse_uint(t).ok_or_else(|| format!("{key} is no number")),
            Some(_) => Err(format!("{key} is no number")),
            None => Err(format!("{key} is not set")),
        }
    }

    // What: value as bool.
    // Why: only bool keys answer; others are errors.
    // From: Issue #1683 | PR #1980
    pub fn flag(&self, key: &str) -> Result<bool, String> {
        match self.get(key) {
            Some(Value::Bool(b)) => Ok(*b),
            // What: text answers only as true or false.
            // Why: AG-SEC-001 names ALLOW_INSECURE_UI=true.
            // From: Issue #1683 | PR #2017
            Some(Value::Text(t)) => t.parse().map_err(|_| format!("{key} is no bool")),
            Some(_) => Err(format!("{key} is no bool")),
            None => Err(format!("{key} is not set")),
        }
    }

    // What: value as a narrower number type.
    // Why: callers need usize, u32 or u16, not u64.
    // From: Issue #1683 | PR #2017
    pub fn num<T: TryFrom<u64>>(&self, key: &str) -> Result<T, String> {
        T::try_from(self.uint(key)?).map_err(|_| format!("{key} is out of range"))
    }

    // What: value as file mode, read as octal text.
    // Why: the SOT owns every file mode, like 0640.
    // From: Issue #1683 | PR #2017
    pub fn mode(&self, key: &str) -> Result<u32, String> {
        u32::from_str_radix(&self.text(key)?, 8).map_err(|e| format!("{key}: {e}"))
    }

    // What: value as items; missing is empty.
    // Why: an unset optional list means no entries.
    // From: Issue #1683 | PR #1980
    pub fn list(&self, key: &str) -> Vec<String> {
        match self.get(key) {
            Some(Value::List(items)) => items.clone(),
            Some(other) => list_items(&other.to_string()).map(str::to_string).collect(),
            None => Vec::new(),
        }
    }

    // What: check one raw value for a key.
    // Why: forms are checked before they are stored.
    // From: Issue #1683 | PR #1980
    pub fn validate(&self, key: &str, raw: &str) -> Result<Value, String> {
        self.spec(key)
            .ok_or_else(|| format!("{key} is not a known setting"))?
            .check(raw)
            .map(|(value, _)| value)
    }

    // What: FNV-1a id of all non-secret values.
    // Why: shows which config is live.
    // From: Issue #1683 | PR #1980
    pub fn revision(&self) -> String {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for (key, value) in self.texts() {
            let line = format!("{key}={value}\0");
            for byte in line.bytes() {
                hash ^= u64::from(byte);
                hash = hash.wrapping_mul(0x0100_0000_01b3);
            }
        }
        format!("{hash:016x}")
    }

    // What: keys whose value differs in newer.
    // Why: the runner acts per owner and effect.
    // From: Issue #1683 | PR #1980
    pub fn diff(&self, newer: &Self) -> Vec<Change> {
        let keys: BTreeSet<&String> = self.values.keys().chain(newer.values.keys()).collect();
        keys.into_iter()
            .filter(|k| self.values.get(*k) != newer.values.get(*k))
            .filter_map(|k| newer.specs.get(k).or_else(|| self.specs.get(k)))
            .map(|spec| Change {
                key: spec.key.clone(),
                owner: spec.owner.clone(),
                effect: spec.effect,
            })
            .collect()
    }
}

// What: one changed key.
// Why: owner and effect drive reload or restart.
// From: Issue #1683 | PR #1858
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Change {
    pub key: String,
    pub owner: String,
    pub effect: Effect,
}

// What: reader for the process environment.
// Why: Settings::load takes any reader.
// From: Issue #1683 | PR #1980
pub fn process_env(name: &str) -> Option<String> {
    std::env::var(name).ok()
}
