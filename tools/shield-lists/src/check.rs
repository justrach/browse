//! What the lists mean against what browse does with them.
//!
//!     shield-lists check RULES.json LIST… < requests.tsv > verdicts.tsv
//!
//! Each request (a line of `url  page  type`, tab-separated; `type` in
//! WebKit's words — image, script, style-sheet, font, raw, document, media,
//! other) is put to two judges:
//!
//! - the lists themselves, read by Brave's adblock engine — what the people
//!   who write EasyList mean;
//! - the WebKit rules browse carries (network.json), matched the way WebKit
//!   matches them: every rule in order, the last `block` or
//!   `ignore-previous-rules` that fits deciding.
//!
//! Where they differ is where the conversion went wrong: the lists wanted
//! it blocked and browse lets it through, or the other way round — which is
//! how google.com/logos/ went missing.
//!
//! Out, tab-separated: url, page, type, what the lists say, what browse
//! does, the list filter behind the first, the WebKit filter behind the
//! second.

use adblock::lists::{FilterSet, ParseOptions, RuleTypes};
use adblock::request::Request;
use adblock::Engine;
use aho_corasick::AhoCorasick;
use regex::{Regex, RegexBuilder};
use serde_json::Value;
use std::collections::HashMap;
use std::io::{BufRead, Write};

struct Rule {
    filter: String,
    regex: Regex,
    block: bool,
    if_domain: Vec<String>,
    unless_domain: Vec<String>,
    load: Option<bool>, // Some(true): third-party only
    types: Vec<String>,
}

/// The longest run of plain characters a filter can't match without:
/// what's searched for first, so each request is tried against a few
/// hundred rules rather than all of them. Anything in a group or before a
/// quantifier may be absent, so it doesn't count.
fn needle(filter: &str) -> String {
    let mut best = String::new();
    let mut run = String::new();
    let mut chars = filter.chars().peekable();
    let mut depth = 0;
    let end = |run: &mut String, best: &mut String| {
        if run.len() > best.len() {
            *best = run.clone();
        }
        run.clear();
    };
    while let Some(c) = chars.next() {
        match c {
            '(' => {
                depth += 1;
                end(&mut run, &mut best);
            }
            ')' => depth -= 1,
            _ if depth > 0 => {
                if c == '\\' {
                    chars.next();
                }
            }
            '\\' => {
                let escaped = chars.next().unwrap_or('\\');
                if matches!(chars.peek(), Some('*' | '?')) {
                    end(&mut run, &mut best);
                } else {
                    run.push(escaped.to_ascii_lowercase());
                }
            }
            '[' => {
                end(&mut run, &mut best);
                for d in chars.by_ref() {
                    if d == ']' {
                        break;
                    }
                }
            }
            '*' | '?' => {
                run.pop();
                end(&mut run, &mut best);
            }
            '.' | '+' | '^' | '$' | '|' => end(&mut run, &mut best),
            _ => {
                if matches!(chars.peek(), Some('*' | '?')) {
                    end(&mut run, &mut best);
                } else {
                    run.push(c.to_ascii_lowercase());
                }
            }
        }
    }
    end(&mut run, &mut best);
    best
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_lowercase)).collect())
        .unwrap_or_default()
}

fn load(path: &str) -> Vec<Rule> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("{path}: {e}");
        std::process::exit(1);
    });
    let raw: Vec<Value> = serde_json::from_str(&text).expect("rules are JSON");
    raw.iter()
        .filter_map(|r| {
            let action = r["action"]["type"].as_str()?;
            let block = match action {
                "block" => true,
                "ignore-previous-rules" => false,
                _ => return None,
            };
            let t = &r["trigger"];
            let filter = t["url-filter"].as_str()?.to_string();
            let sensitive = t["url-filter-is-case-sensitive"].as_bool().unwrap_or(false);
            let regex = RegexBuilder::new(&filter).case_insensitive(!sensitive).build().ok()?;
            let loads = strings(&t["load-type"]);
            Some(Rule {
                filter,
                regex,
                block,
                if_domain: strings(&t["if-domain"]),
                unless_domain: strings(&t["unless-domain"]),
                load: match loads.as_slice() {
                    [one] => Some(one == "third-party"),
                    _ => None,
                },
                types: strings(&t["resource-type"]),
            })
        })
        .collect()
}

fn host(url: &str) -> String {
    url::Url::parse(url).ok().and_then(|u| u.host_str().map(str::to_lowercase)).unwrap_or_default()
}

fn site(host: &str) -> String {
    psl::domain_str(host).unwrap_or(host).to_string()
}

fn domain_fits(list: &[String], host: &str) -> bool {
    list.iter().any(|d| match d.strip_prefix('*') {
        Some(rest) => host == rest || host.ends_with(&format!(".{rest}")),
        None => host == d,
    })
}

/// Brave's engine names types its own way.
fn engine_type(webkit: &str) -> &str {
    match webkit {
        "style-sheet" => "stylesheet",
        "raw" | "fetch" => "xmlhttprequest",
        "document" => "sub_frame",
        other => other,
    }
}

pub fn run(mut args: impl Iterator<Item = String>) {
    let Some(rules_path) = args.next() else {
        eprintln!("usage: shield-lists check RULES.json LIST… < requests.tsv");
        std::process::exit(2);
    };
    let rules = load(&rules_path);
    let needles: Vec<String> = rules.iter().map(|r| needle(&r.filter)).collect();
    let (with, always): (Vec<usize>, Vec<usize>) = (0..rules.len()).partition(|&i| !needles[i].is_empty());
    let finder = AhoCorasick::new(with.iter().map(|&i| &needles[i])).expect("needles build");

    let mut set = FilterSet::new(true);
    for path in args {
        let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            eprintln!("{path}: {e}");
            std::process::exit(1);
        });
        set.add_filter_list(text, ParseOptions { rule_types: RuleTypes::NetworkOnly, ..Default::default() });
    }
    let engine = Engine::new_with_filter_set_no_optimize(set);
    eprintln!("{} WebKit rules ({} always tried)", rules.len(), always.len());

    let mut cache: HashMap<String, Vec<usize>> = HashMap::new();
    let out = std::io::stdout();
    let mut out = out.lock();
    for line in std::io::stdin().lock().lines().map_while(Result::ok) {
        let mut parts = line.split('\t');
        let (Some(url), Some(page), Some(kind)) = (parts.next(), parts.next(), parts.next()) else { continue };

        let (says, why) = match Request::new(url, page, engine_type(kind), "GET") {
            Ok(request) => {
                let result = engine.check_network_request(&request);
                let decided = if result.should_block() { &result.filter } else { &result.exception };
                let why = decided.as_ref().and_then(|d| d.raw_line.clone()).unwrap_or_default();
                (if result.should_block() { "block" } else { "allow" }, why)
            }
            Err(_) => ("allow", String::new()),
        };

        let lower = url.to_lowercase();
        let candidates = cache.entry(lower.clone()).or_insert_with(|| {
            let mut found: Vec<usize> =
                finder.find_overlapping_iter(&lower).map(|m| with[m.pattern().as_usize()]).collect();
            found.extend(&always);
            found.sort_unstable();
            found.dedup();
            found
        });
        let (page_host, url_host) = (host(page), host(url));
        let third = site(&page_host) != site(&url_host);
        let mut verdict: Option<&Rule> = None;
        for &i in candidates.iter() {
            let rule = &rules[i];
            if !rule.types.is_empty() && !rule.types.iter().any(|t| t == kind) {
                continue;
            }
            if rule.load.is_some_and(|wants_third| wants_third != third) {
                continue;
            }
            if !rule.if_domain.is_empty() && !domain_fits(&rule.if_domain, &page_host) {
                continue;
            }
            if domain_fits(&rule.unless_domain, &page_host) {
                continue;
            }
            if rule.regex.is_match(url) {
                verdict = Some(rule);
            }
        }
        let does = if verdict.is_some_and(|r| r.block) { "block" } else { "allow" };
        let webkit = verdict.map(|r| r.filter.as_str()).unwrap_or("");
        let _ = writeln!(out, "{url}\t{page}\t{kind}\t{says}\t{does}\t{why}\t{webkit}");
    }
}
