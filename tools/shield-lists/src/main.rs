//! Filter lists in Adblock Plus syntax in, WebKit content blocker rules out.
//!
//!     shield-lists network|cosmetic LIST… > rules.json
//!
//! `network` is what's blocked before it's fetched; `cosmetic` is what's
//! hidden once it's on the page. They're compiled as two lists, so each
//! stays well under the rules WebKit takes in one.

use adblock::lists::{FilterSet, ParseOptions, RuleTypes};

fn main() {
    let mut args = std::env::args().skip(1);
    let rule_types = match args.next().as_deref() {
        Some("network") => RuleTypes::NetworkOnly,
        Some("cosmetic") => RuleTypes::CosmeticOnly,
        _ => {
            eprintln!("usage: shield-lists network|cosmetic LIST… > rules.json");
            std::process::exit(2);
        }
    };
    let mut set = FilterSet::new(true);
    for path in args {
        let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            eprintln!("{path}: {e}");
            std::process::exit(1);
        });
        set.add_filter_list(text, ParseOptions { rule_types, ..Default::default() });
    }
    let (rules, used) = set.into_content_blocking().expect("a debug FilterSet converts");
    eprintln!("{} rules from {} filters", rules.len(), used.len());
    println!("{}", serde_json::to_string(&rules).expect("rules serialize"));
}
