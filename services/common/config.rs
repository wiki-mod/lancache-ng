//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: one typed settings model for every crate.
//! Why: the SOT owns keys, types, ranges and effects.
//! From: Issue #1683 | PR #1858

use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

// What: env name of the SOT defaults baked into images.
// Why: ci.sh writes it from build-manifest.yml runtime.
// From: Issue #1683 | PR #1858
pub const DEFAULTS_KEY: &str = "LANCACHE_RUNTIME_DEFAULTS";

// What: env name of the SOT schema baked into images.
// Why: types, ranges and effects come from the SOT only.
// From: Issue #1683 | PR #1858
pub const SCHEMA_KEY: &str = "LANCACHE_RUNTIME_SCHEMA";

// What: separator between entries of a baked SOT list.
// Why: ci.sh joins entries with it; values hold no pipe.
// From: Issue #1683 | PR #1858
const ENTRY_SEP: char = '|';

// What: separator between fields of one schema entry.
// Why: the schema entry is KEY=kind;min;max;effect;owner.
// From: Issue #1683 | PR #1858
const FIELD_SEP: char = ';';

// What: the type of one setting.
// Why: one parser per type; no per-key parsing code.
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

// What: what a changed value needs to take effect.
// Why: the ui shows it; only affected programs act.
// From: Issue #1683 | PR #1858
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Effect {
    Live,
    Reload,
    Restart,
    Container,
    Recreate,
}

impl Effect {
    // What: the effect from its SOT word.
    // Why: unknown words fail; a typo must not be Live.
    // From: Issue #1683 | PR #1858
    fn parse(raw: &str) -> Result<Self, String> {
        match raw {
            "live" => Ok(Self::Live),
            "reload" => Ok(Self::Reload),
            "restart" => Ok(Self::Restart),
            "container" => Ok(Self::Container),
            "recreate" => Ok(Self::Recreate),
            other => Err(format!("unknown effect {other:?}")),
        }
    }
}

// What: one setting as the SOT schema declares it.
// Why: key, type, need, effect and owner live together.
// From: Issue #1683 | PR #1858
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Spec {
    pub key: String,
    pub kind: Kind,
    pub required: bool,
    pub effect: Effect,
    pub owner: String,
}

impl Spec {
    // What: one entry KEY=kind;min;max;effect;owner.
    // Why: a trailing ? on kind marks an optional key.
    // From: Issue #1683 | PR #1858
    fn parse(entry: &str) -> Result<Self, String> {
        let (key, rest) = entry
            .split_once('=')
            .ok_or_else(|| format!("schema entry without '=': {entry:?}"))?;
        let fields: Vec<&str> = rest.split(FIELD_SEP).collect();
        let [kind, min, max, effect, owner] = fields[..] else {
            return Err(format!(
                "{key}: schema needs 5 fields, got {}",
                fields.len()
            ));
        };
        let (kind, required) = match kind.strip_suffix('?') {
            Some(base) => (base, false),
            None => (kind, true),
        };
        let number = |raw: &str| {
            raw.parse::<u64>()
                .map_err(|_| format!("{key}: bad limit {raw:?}"))
        };
        let kind = match kind {
            "text" => Kind::Text,
            "bool" => Kind::Bool,
            "list" => Kind::List,
            "path" => Kind::Path,
            "secret" => Kind::Secret,
            "uint" | "uint~" => {
                let (min, max) = (number(min)?, number(max)?);
                if min > max {
                    return Err(format!("{key}: min {min} above max {max}"));
                }
                Kind::Uint {
                    min,
                    max,
                    clamp: kind == "uint~",
                }
            }
            // What: a choice lists its words in the min field.
            // Why: max stays empty; the words are comma-joined.
            // From: Issue #1683 | PR #1858
            "choice" => Kind::Choice(list_items(min).map(str::to_string).collect()),
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
}

// What: a checked value of one setting.
// Why: callers get the type, not a string to reparse.
// From: Issue #1683 | PR #1858
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Value {
    Text(String),
    Bool(bool),
    Uint(u64),
    List(Vec<String>),
}

impl fmt::Display for Value {
    // What: the normal text form of a value.
    // Why: revision and diff compare this form only.
    // From: Issue #1683 | PR #1858
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Text(v) => f.write_str(v),
            Self::Bool(v) => write!(f, "{v}"),
            Self::Uint(v) => write!(f, "{v}"),
            Self::List(v) => f.write_str(&v.join(",")),
        }
    }
}

// What: items of a list split by commas or blanks.
// Why: one splitter for every list; empty items drop.
// From: Issue #1683 | PR #1858
pub fn list_items(raw: &str) -> impl Iterator<Item = &str> {
    raw.split([',', ' ', '\r', '\n', '\t'])
        .filter(|item| !item.is_empty())
}

// What: 1/true/yes/on or 0/false/no/off, any case.
// Why: one boolean grammar for every service.
// From: Issue #1683 | PR #1858
pub fn parse_bool(raw: &str) -> Option<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

// What: one raw value checked against its spec.
// Why: one check for every key; a warning on clamp.
// From: Issue #1683 | PR #1858
fn check(spec: &Spec, raw: &str) -> Result<(Value, Option<String>), String> {
    let key = &spec.key;
    let raw = raw.trim();
    let value = match &spec.kind {
        Kind::Text | Kind::Path | Kind::Secret => Value::Text(raw.to_string()),
        Kind::List => Value::List(list_items(raw).map(str::to_string).collect()),
        Kind::Bool => Value::Bool(
            parse_bool(raw).ok_or_else(|| format!("{key} must be a boolean, got {raw:?}"))?,
        ),
        Kind::Choice(words) => {
            if !words.iter().any(|w| w == raw) {
                return Err(format!("{key}={raw:?} is not one of {}", words.join(",")));
            }
            Value::Text(raw.to_string())
        }
        Kind::Uint { min, max, clamp } => {
            // What: ASCII digits only.
            // Why: u64 parsing alone accepts a leading plus.
            // From: Issue #1683 | PR #1858
            if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
                return Err(format!("{key}={raw:?} is not an unsigned number"));
            }
            let n = raw
                .parse::<u64>()
                .map_err(|_| format!("{key}={raw} is too large"))?;
            let limit = n.clamp(*min, *max);
            if limit != n && !clamp {
                return Err(format!("{key}={n} is outside {min}..={max}"));
            }
            let note =
                (limit != n).then(|| format!("{key}={n} outside {min}..={max}; using {limit}"));
            return Ok((Value::Uint(limit), note));
        }
    };
    Ok((value, None))
}

// What: KEY=value pairs of a baked SOT list.
// Why: defaults and schema travel as one pipe-joined env.
// From: Issue #1683 | PR #1858
fn pairs(list: &str) -> impl Iterator<Item = &str> {
    list.split(ENTRY_SEP).filter(|e| !e.trim().is_empty())
}

// What: the KEY=value lines of the ui settings file.
// Why: the ui stores admin values; a missing file is empty.
// From: Issue #1683 | PR #1858
fn saved(path: &Path) -> Result<BTreeMap<String, String>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
        Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
    };
    Ok(text
        .lines()
        .filter_map(|line| line.trim().split_once('='))
        .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        .collect())
}

// What: merge checked updates into the saved file.
// Why: same KEY=VALUE format the reader above parses.
// From: Issue #1683 | PR #1858
pub fn store(
    path: &Path,
    current: &Settings,
    updates: &BTreeMap<String, String>,
) -> Result<(), String> {
    let mut all = saved(path)?;
    for (k, raw) in updates {
        if raw.contains(['\n', '\r']) {
            return Err(format!("{k}: line break not allowed"));
        }
        if !raw.is_empty() {
            current.validate(k, raw)?;
        }
        all.insert(k.clone(), raw.clone());
    }
    let body: String = all.iter().map(|(k, v)| format!("{k}={v}\n")).collect();
    let keep = crate::fs::Owner {
        uid: None,
        gid: None,
    };
    crate::fs::write(
        path,
        body.as_bytes(),
        0o600,
        crate::fs::Place::Replace,
        keep,
    )
    .map_err(|e| format!("{}: {e}", path.display()))
}

// What: one loaded and checked settings set.
// Why: every crate reads values only through this set.
// From: Issue #1683 | PR #1858
#[derive(Clone, Debug, Default)]
pub struct Settings {
    specs: BTreeMap<String, Spec>,
    values: BTreeMap<String, Value>,
    pub warnings: Vec<String>,
}

impl Settings {
    // What: schema, then env over saved over SOT default.
    // Why: an admin value beats the default; env beats both.
    // From: Issue #1683 | PR #1858
    pub fn load(
        env: &dyn Fn(&str) -> Option<String>,
        saved_file: Option<&Path>,
    ) -> Result<Self, String> {
        let schema = env(SCHEMA_KEY).ok_or_else(|| format!("{SCHEMA_KEY} is not set"))?;
        let defaults = env(DEFAULTS_KEY).unwrap_or_default();
        let defaults: BTreeMap<&str, &str> =
            pairs(&defaults).filter_map(|p| p.split_once('=')).collect();
        let stored = match saved_file {
            Some(path) => saved(path)?,
            None => BTreeMap::new(),
        };
        let mut set = Self::default();
        let mut errors = Vec::new();
        for entry in pairs(&schema) {
            let spec = match Spec::parse(entry) {
                Ok(spec) => spec,
                Err(e) => {
                    errors.push(e);
                    continue;
                }
            };
            let raw = env(&spec.key)
                .filter(|v| !v.is_empty())
                .or_else(|| stored.get(&spec.key).filter(|v| !v.is_empty()).cloned())
                .or_else(|| defaults.get(spec.key.as_str()).map(|v| v.to_string()))
                .filter(|v| !v.is_empty());
            match raw {
                Some(raw) => match check(&spec, &raw) {
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
        // What: every problem at once, not only the first.
        // Why: an admin fixes all keys in one pass.
        // From: Issue #1683 | PR #1858
        if errors.is_empty() {
            Ok(set)
        } else {
            Err(errors.join("; "))
        }
    }

    // What: the spec of one key, if the SOT declares it.
    // Why: the ui builds its fields from the spec.
    // From: Issue #1683 | PR #1858
    pub fn spec(&self, key: &str) -> Option<&Spec> {
        self.specs.get(key)
    }

    // What: every declared spec in key order.
    // Why: the ui lists all settings without its own list.
    // From: Issue #1683 | PR #1858
    pub fn specs(&self) -> impl Iterator<Item = &Spec> {
        self.specs.values()
    }

    // What: the checked value of one key, if set.
    // Why: optional keys may be absent.
    // From: Issue #1683 | PR #1858
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.values.get(key)
    }

    // What: a value as text; an unset key is an error.
    // Why: callers that need a value fail with its name.
    // From: Issue #1683 | PR #1858
    pub fn text(&self, key: &str) -> Result<String, String> {
        self.get(key)
            .map(Value::to_string)
            .ok_or_else(|| format!("{key} is not set"))
    }

    // What: a number value; other types are an error.
    // Why: a wrong SOT kind must not read as zero.
    // From: Issue #1683 | PR #1858
    pub fn uint(&self, key: &str) -> Result<u64, String> {
        match self.get(key) {
            Some(Value::Uint(n)) => Ok(*n),
            Some(_) => Err(format!("{key} is not a number in the SOT")),
            None => Err(format!("{key} is not set")),
        }
    }

    // What: a boolean value; other types are an error.
    // Why: a wrong SOT kind must not read as false.
    // From: Issue #1683 | PR #1858
    pub fn flag(&self, key: &str) -> Result<bool, String> {
        match self.get(key) {
            Some(Value::Bool(b)) => Ok(*b),
            Some(_) => Err(format!("{key} is not a boolean in the SOT")),
            None => Err(format!("{key} is not set")),
        }
    }

    // What: a list value; a text value splits as a list.
    // Why: unset optional lists are empty.
    // From: Issue #1683 | PR #1858
    pub fn list(&self, key: &str) -> Vec<String> {
        match self.get(key) {
            Some(Value::List(v)) => v.clone(),
            Some(other) => list_items(&other.to_string()).map(str::to_string).collect(),
            None => Vec::new(),
        }
    }

    // What: one admin value checked before it is stored.
    // Why: the ui rejects bad input with the SOT rule.
    // From: Issue #1683 | PR #1858
    pub fn validate(&self, key: &str, raw: &str) -> Result<Value, String> {
        let spec = self
            .spec(key)
            .ok_or_else(|| format!("{key} is not a known setting"))?;
        check(spec, raw).map(|(value, _)| value)
    }

    // What: a stable id of all effective non-secret values.
    // Why: shows which config is live without file times.
    // From: Issue #1683 | PR #1858
    pub fn revision(&self) -> String {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for (key, value) in &self.values {
            if matches!(self.specs.get(key).map(|s| &s.kind), Some(Kind::Secret)) {
                continue;
            }
            for byte in key
                .bytes()
                .chain([b'='])
                .chain(value.to_string().bytes())
                .chain([0])
            {
                hash ^= u64::from(byte);
                hash = hash.wrapping_mul(0x0100_0000_01b3);
            }
        }
        format!("{hash:016x}")
    }

    // What: changed keys with their owner and effect.
    // Why: only the owning programs reload or restart.
    // From: Issue #1683 | PR #1858
    pub fn diff(&self, newer: &Self) -> Vec<Change> {
        let keys: std::collections::BTreeSet<&String> =
            self.values.keys().chain(newer.values.keys()).collect();
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

// What: one changed key and what it needs.
// Why: the ui and the process runner act on this list.
// From: Issue #1683 | PR #1858
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Change {
    pub key: String,
    pub owner: String,
    pub effect: Effect,
}

// What: the live process environment as a reader.
// Why: Settings::load takes any reader.
// From: Issue #1683 | PR #1858
pub fn process_env(name: &str) -> Option<String> {
    std::env::var(name).ok()
}
