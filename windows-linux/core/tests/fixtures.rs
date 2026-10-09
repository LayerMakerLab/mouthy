//! Shared behavior vectors with the Mac app (shared/text-rules.json).
use serde_json::Value;
use mouthy_core::*;

fn fixtures() -> Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../shared/text-rules.json");
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}
fn s<'a>(v: &'a Value, key: &str) -> &'a str { v[key].as_str().unwrap() }

#[test]
fn smart_insertion_matches_fixtures() {
    for case in fixtures()["smartInsertion"].as_array().unwrap() {
        assert_eq!(smart_insertion(s(case, "text"), s(case, "before"), s(case, "after")), s(case, "expected"), "{case}");
    }
}
#[test]
fn backtrack_matches_fixtures() {
    for case in fixtures()["backtrack"].as_array().unwrap() {
        assert_eq!(backtrack(s(case, "text")), s(case, "expected"), "{case}");
    }
}
#[test]
fn spoken_punctuation_matches_fixtures() {
    for case in fixtures()["spokenPunctuation"].as_array().unwrap() {
        assert_eq!(spoken_punctuation(s(case, "text")), s(case, "expected"), "{case}");
    }
}
#[test]
fn process_matches_fixtures() {
    for case in fixtures()["process"].as_array().unwrap() {
        let rules: Vec<Replacement> = serde_json::from_value(case["replacements"].clone()).unwrap();
        assert_eq!(process(s(case, "text"), &rules, case["punctuation"].as_bool().unwrap()), s(case, "expected"), "{case}");
    }
}
#[test]
fn trigger_matches_fixtures() {
    for case in fixtures()["trigger"].as_array().unwrap() {
        let modes: Vec<DictationMode> = case["triggers"].as_array().unwrap().iter()
            .map(|t| DictationMode { name: t.as_str().unwrap().into(), trigger_word: t.as_str().unwrap().into(), ..Default::default() })
            .collect();
        let found = trigger(s(case, "text"), &modes);
        match case["mode"].as_str() {
            Some(name) => {
                let (mode, rest) = found.expect("trigger");
                assert_eq!(mode.name, name);
                assert_eq!(rest, s(case, "expected"));
            }
            None => assert!(found.is_none(), "{case}"),
        }
    }
}
#[test]
fn fillers_match_fixtures() {
    for case in fixtures()["fillers"].as_array().unwrap() {
        assert_eq!(remove_fillers(&remove_hesitation_dots(s(case, "text"))), s(case, "expected"), "{case}");
    }
}
#[test]
fn code_matches_fixtures() {
    for case in fixtures()["code"].as_array().unwrap() {
        assert_eq!(code_dictation(s(case, "text")), s(case, "expected"), "{case}");
    }
}
#[test]
fn modes_follow_priority() {
    let app = DictationMode { name: "Slack".into(), apps: vec!["slack.exe".into()], ..Default::default() };
    let site = DictationMode { name: "GitHub".into(), websites: vec!["github.com".into()], ..Default::default() };
    let keyed = DictationMode { name: "Keyed".into(), apps: vec!["slack.exe".into()], ..Default::default() };
    let modes = vec![app, site, keyed.clone()];
    assert_eq!(start_mode(&modes, Some(keyed.id), Some("https://github.com/x"), "slack.exe").unwrap().name, "Keyed");
    assert_eq!(start_mode(&modes, None, Some("https://gist.github.com/x"), "Slack.exe").unwrap().name, "GitHub");
    assert_eq!(start_mode(&modes, None, Some("https://notgithub.com"), "slack.exe").unwrap().name, "Slack");
    assert!(start_mode(&modes, None, None, "notepad.exe").is_none());
}
#[test]
fn settings_tolerate_missing_fields() {
    let settings: Settings = serde_json::from_str("{}").unwrap();
    assert!(settings.smart_formatting && settings.modes.is_empty());
}
