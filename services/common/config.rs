//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// What: settings from SOT schema, defaults, file, env.
// Why: every crate reads values through one checked set.
// From: Issue #1683 | PR #1858

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::Path;

// What: env key of the baked default rows.
// Why: the SOT bakes defaults into each image.
// From: Issue #1683 | PR #1858
pub const DEFAULTS_KEY: &str = "LANCACHE_RUNTIME_DEFAULTS";

// What: env key of the baked schema rows.
// Why: kind, range, effect and owner per key.
// From: Issue #1683 | PR #1858
pub const SCHEMA_KEY: &str = "LANCACHE_RUNTIME_SCHEMA";

// What: separator of baked rows.
// Why: the SOT joins rows with a pipe.
// From: Issue #1683 | PR #1858
const ROW_SEP: char = '|';

// What: type of a value.
// Why: the schema kind decides parsing and the ui field.
// From: Issue #1683 | PR #1858
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
// From: Issue #1683 | PR #1858
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
// From: Issue #1683 | PR #1858
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
// From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
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
// From: Issue #1683 | PR #1858
pub fn list_items(raw: &str) -> impl Iterator<Item = &str> {
    raw.split(|c: char| c == ',' || c.is_whitespace())
        .filter(|item| !item.is_empty())
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
// From: Issue #1683 | PR #1858
fn parse_uint(raw: &str) -> Option<u64> {
    if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    raw.parse().ok()
}

impl Effect {
    // What: effect from its SOT word.
    // Why: an unknown word is an error, never Live.
    // From: Issue #1683 | PR #1858
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
    // What: parse KEY=kind;min;max;effect;owner.
    // Why: the SOT schema row format.
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
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
// From: Issue #1683 | PR #1858
fn baked_rows(baked: &str) -> impl Iterator<Item = &str> {
    baked
        .split(ROW_SEP)
        .map(str::trim)
        .filter(|r| !r.is_empty())
}

// What: KEY=VALUE lines of the admin file.
// Why: a missing file means no admin values yet.
// From: Issue #1683 | PR #1858
fn read_file(path: &Path) -> Result<BTreeMap<String, String>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    Ok(text
        .lines()
        .filter_map(|line| line.split_once('='))
        .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        .collect())
}

// What: write checked admin values to the file.
// Why: empty value removes the admin override.
// From: Issue #1683 | PR #1858
pub fn store(
    path: &Path,
    current: &Settings,
    updates: &BTreeMap<String, String>,
) -> Result<(), String> {
    let mut all = read_file(path)?;
    for (key, raw) in updates {
        if raw.contains(['\n', '\r']) {
            return Err(format!("{key}: line break not allowed"));
        }
        if raw.is_empty() {
            all.remove(key);
            continue;
        }
        current.validate(key, raw)?;
        all.insert(key.clone(), raw.clone());
    }
    let body: String = all.iter().map(|(k, v)| format!("{k}={v}\n")).collect();
    let owner = crate::fs::Owner {
        uid: None,
        gid: None,
    };
    crate::fs::write(
        path,
        body.as_bytes(),
        0o600,
        crate::fs::Place::Replace,
        owner,
    )
    .map_err(|e| format!("{}: {e}", path.display()))
}

// What: the checked settings of one process.
// Why: one load at start; reload builds a new set.
// From: Issue #1683 | PR #1858
#[derive(Clone, Debug, Default)]
pub struct Settings {
    specs: BTreeMap<String, Spec>,
    values: BTreeMap<String, Value>,
    pub warnings: Vec<String>,
}

impl Settings {
    // What: load schema, then file > env > default.
    // Why: a ui change is newer than the .env at start.
    // From: Issue #1683 | PR #1858
    pub fn load(
        env: &dyn Fn(&str) -> Option<String>,
        saved_file: Option<&Path>,
    ) -> Result<Self, String> {
        let schema = env(SCHEMA_KEY).ok_or_else(|| format!("{SCHEMA_KEY} is not set"))?;
        let baked = env(DEFAULTS_KEY).unwrap_or_default();
        let defaults: BTreeMap<&str, &str> = baked_rows(&baked)
            .filter_map(|r| r.split_once('='))
            .collect();
        let file = match saved_file {
            Some(path) => read_file(path)?,
            None => BTreeMap::new(),
        };
        let mut set = Self::default();
        let mut errors = Vec::new();
        for row in baked_rows(&schema) {
            let spec = match Spec::parse(row) {
                Ok(spec) => spec,
                Err(e) => {
                    errors.push(e);
                    continue;
                }
            };
            let raw = file
                .get(&spec.key)
                .filter(|v| !v.is_empty())
                .cloned()
                .or_else(|| env(&spec.key).filter(|v| !v.is_empty()))
                .or_else(|| {
                    defaults
                        .get(spec.key.as_str())
                        .filter(|v| !v.is_empty())
                        .map(|v| v.to_string())
                });
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
            let raw = env(key).filter(|v| !v.is_empty());
            let raw = raw.unwrap_or_else(|| value.to_string());
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
    // From: Issue #1683 | PR #1858
    pub fn spec(&self, key: &str) -> Option<&Spec> {
        self.specs.get(key)
    }

    // What: all schema rows in key order.
    // Why: the setup page lists every setting.
    // From: Issue #1683 | PR #1858
    pub fn specs(&self) -> impl Iterator<Item = &Spec> {
        self.specs.values()
    }

    // What: the checked value of one key.
    // Why: optional keys may have none.
    // From: Issue #1683 | PR #1858
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.values.get(key)
    }

    // What: all loaded values, secrets left out.
    // Why: templates show fixed SOT values as well.
    // From: Issue #1683 | PR #1980
    pub fn texts(&self) -> impl Iterator<Item = (&String, String)> {
        self.values
            .iter()
            .filter(|(k, _)| !matches!(self.specs.get(*k).map(|sp| &sp.kind), Some(Kind::Secret)))
            .map(|(k, v)| (k, v.to_string()))
    }

    // What: value as text; missing is an error.
    // Why: the error names the key.
    // From: Issue #1683 | PR #1858
    pub fn text(&self, key: &str) -> Result<String, String> {
        // What: a compose-only key falls back to the env.
        // Why: operator keys like IP_HTTPS have no SOT row.
        // From: Issue #1683 | PR #1980
        self.get(key)
            .map(Value::to_string)
            .or_else(|| std::env::var(key).ok().filter(|v| !v.is_empty()))
            .ok_or_else(|| format!("{key} is not set"))
    }

    // What: value as number.
    // Why: only uint keys answer; others are errors.
    // From: Issue #1683 | PR #1858
    pub fn uint(&self, key: &str) -> Result<u64, String> {
        match self.get(key) {
            Some(Value::Uint(n)) => Ok(*n),
            // What: a fixed SOT default is text; parse it.
            // Why: keys without schema row load as text.
            // From: Issue #1683 | PR #1980
            Some(Value::Text(t)) => t.parse().map_err(|_| format!("{key} is no number")),
            Some(_) => Err(format!("{key} is no number")),
            None => Err(format!("{key} is not set")),
        }
    }

    // What: value as bool.
    // Why: only bool keys answer; others are errors.
    // From: Issue #1683 | PR #1858
    pub fn flag(&self, key: &str) -> Result<bool, String> {
        match self.get(key) {
            Some(Value::Bool(b)) => Ok(*b),
            Some(Value::Text(t)) => t.parse().map_err(|_| format!("{key} is no bool")),
            Some(_) => Err(format!("{key} is no bool")),
            None => Err(format!("{key} is not set")),
        }
    }

    // What: value as items; missing is empty.
    // Why: an unset optional list means no entries.
    // From: Issue #1683 | PR #1858
    pub fn list(&self, key: &str) -> Vec<String> {
        match self.get(key) {
            Some(Value::List(items)) => items.clone(),
            Some(other) => list_items(&other.to_string()).map(str::to_string).collect(),
            None => Vec::new(),
        }
    }

    // What: check one raw value for a key.
    // Why: forms are checked before they are stored.
    // From: Issue #1683 | PR #1858
    pub fn validate(&self, key: &str, raw: &str) -> Result<Value, String> {
        self.spec(key)
            .ok_or_else(|| format!("{key} is not a known setting"))?
            .check(raw)
            .map(|(value, _)| value)
    }

    // What: FNV-1a id of all non-secret values.
    // Why: shows which config is live.
    // From: Issue #1683 | PR #1858
    pub fn revision(&self) -> String {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        let public = self
            .values
            .iter()
            .filter(|(k, _)| !matches!(self.specs.get(*k).map(|s| &s.kind), Some(Kind::Secret)));
        for (key, value) in public {
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
    // From: Issue #1683 | PR #1858
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
// From: Issue #1683 | PR #1858
pub fn process_env(name: &str) -> Option<String> {
    std::env::var(name).ok()
}
