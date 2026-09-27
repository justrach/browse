//! Filter lists in Adblock Plus syntax in, WebKit content blocker rules out.
//!
//!     shield-lists network|cosmetic LIST… > rules.json
//!     shield-lists check RULES.json LIST… < requests.tsv   (see check.rs)
//!
//! `network` is what's blocked before it's fetched; `cosmetic` is what's
//! hidden once it's on the page. They're compiled as two lists, so each
//! stays well under the rules WebKit takes in one.
//!
//! One thing is put right on the way. A filter ending in `^` ends at a
//! separator — anything but a letter, a digit or `_ - . %` — or at the end
//! of the address. adblock's conversion drops that `^`, and what's left
//! matches as a prefix: `||google.com/log^`, EasyPrivacy's rule for
//! Google's logging, blocked google.com/logos/ and every doodle with it,
//! and `||ads.com^` would block ads.community.org. So each rule is converted
//! again on its own to learn which WebKit filters came from such a `^`, and
//! those get their edge back: a host is always followed by `/` or `:` in the
//! address WebKit matches, and a path by a separator or nothing, which
//! takes two rules, as WebKit's filters have no "or".

mod check;

use adblock::content_blocking::CbRule;
use adblock::lists::{FilterSet, ParseOptions, RuleTypes};
use std::collections::HashMap;

/// What a filter's trailing `^` asked of the WebKit filter made from it.
#[derive(Clone, Copy, PartialEq)]
enum Edge {
    /// `||host^`: the host ends there.
    Host,
    /// `…/path^`: a separator follows, or the address ends.
    Separator,
    /// No trailing `^` — or two filters made the same WebKit filter and only
    /// one had it, so it's left as broad as the broader one.
    Open,
}

fn edge(line: &str) -> Edge {
    let rule = line.strip_prefix("@@").unwrap_or(line);
    if rule.starts_with('/') {
        return Edge::Open; // a regular expression, not a pattern
    }
    let pattern = rule.split('$').next().unwrap_or(rule);
    let Some(body) = pattern.strip_suffix('^') else { return Edge::Open };
    // `…*^` or `…^^` ends nowhere in particular.
    if !body.ends_with(|c: char| c.is_ascii_alphanumeric() || "_.%-".contains(c)) {
        return Edge::Open;
    }
    match body.strip_prefix("||") {
        Some(host) if !host.contains(['/', '*', '^', '|']) => Edge::Host,
        _ => Edge::Separator,
    }
}

fn convert(line: &str, parse: ParseOptions) -> Vec<CbRule> {
    let mut set = FilterSet::new(true);
    set.add_filter_list(line.to_string(), parse);
    set.into_content_blocking().expect("a debug FilterSet converts").0
}

fn main() {
    let mut args = std::env::args().skip(1);
    let rule_types = match args.next().as_deref() {
        Some("network") => RuleTypes::NetworkOnly,
        Some("cosmetic") => RuleTypes::CosmeticOnly,
        Some("check") => return check::run(args),
        _ => {
            eprintln!("usage: shield-lists network|cosmetic|check …");
            std::process::exit(2);
        }
    };
    let parse = ParseOptions { rule_types, ..Default::default() };
    let texts: Vec<String> = args
        .map(|path| {
            std::fs::read_to_string(&path).unwrap_or_else(|e| {
                eprintln!("{path}: {e}");
                std::process::exit(1);
            })
        })
        .collect();

    let mut set = FilterSet::new(true);
    for text in &texts {
        set.add_filter_list(text.clone(), parse);
    }
    let (rules, used) = set.into_content_blocking().expect("a debug FilterSet converts");
    eprintln!("{} rules from {} filters", rules.len(), used.len());
    if !matches!(rule_types, RuleTypes::NetworkOnly) {
        println!("{}", serde_json::to_string(&rules).expect("rules serialize"));
        return;
    }

    // Which WebKit filter came from which kind of ending. A filter on its
    // own converts to its rules plus the first-party document exception
    // every converted list ends with, which is left out here.
    let mut edges: HashMap<String, Edge> = HashMap::new();
    for line in texts.iter().flat_map(|text| text.lines()) {
        let line = line.trim();
        if line.is_empty() || line.starts_with(['!', '[']) {
            continue;
        }
        let mut own = convert(line, parse);
        own.pop();
        let ending = edge(line);
        for rule in own {
            edges
                .entry(rule.trigger.url_filter)
                .and_modify(|seen| if *seen != ending { *seen = Edge::Open })
                .or_insert(ending);
        }
    }

    let (mut hosts, mut paths) = (0, 0);
    let mut out = Vec::with_capacity(rules.len() + 100);
    for mut rule in rules {
        let filter = &rule.trigger.url_filter;
        match edges.get(filter).copied().filter(|_| !filter.ends_with('$')) {
            Some(Edge::Host) => {
                rule.trigger.url_filter += "[/:]";
                hosts += 1;
                out.push(rule);
            }
            Some(Edge::Separator) => {
                let mut end = rule.clone();
                end.trigger.url_filter += "$";
                rule.trigger.url_filter += "[^a-zA-Z0-9_.%-]";
                paths += 1;
                out.push(rule);
                out.push(end);
            }
            _ => out.push(rule),
        }
    }
    eprintln!("{hosts} host endings and {paths} path endings put back");
    println!("{}", serde_json::to_string(&out).expect("rules serialize"));
}
