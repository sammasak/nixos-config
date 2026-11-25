//! A slot helper's counters in node-exporter's textfile directory, one file per counter and slot.

use std::fmt::Write as _;
use std::fs;
use std::path::Path;

/// Adds `n` to the counter `name{labels}` in the textfile `file`, which holds that counter alone, rewritten whole.
///
/// # Errors
/// What writing it reports.
pub fn bump(file: &Path, (name, help): (&str, &str), labels: &str, n: u64) -> std::io::Result<()> {
    let key = format!("{name}{{{labels}}}");
    let mut counts: std::collections::BTreeMap<String, u64> = fs::read_to_string(file)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.rsplit_once(' '))
        .filter(|(k, _)| k.starts_with(name))
        .filter_map(|(k, v)| Some((k.to_owned(), v.parse().ok()?)))
        .collect();
    let count = counts.entry(key).or_default();
    *count = count.saturating_add(n);
    let mut text = format!("# HELP {name} {help}\n# TYPE {name} counter\n");
    for (k, v) in &counts {
        let _ = writeln!(text, "{k} {v}");
    }
    let tmp = file.with_extension("tmp");
    fs::write(&tmp, text)?;
    fs::rename(&tmp, file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counters_are_counted_by_label() -> std::io::Result<()> {
        let dir = std::env::temp_dir().join(format!("exec-pool-bump-{}", std::process::id()));
        fs::create_dir_all(&dir)?;
        let file = dir.join("p.prom");
        let step = "step=\"exec-pool-clone\"";
        bump(&file, crate::runner::PREPARE_FAILURES, step, 1)?;
        bump(&file, crate::runner::PREPARE_FAILURES, step, 1)?;
        bump(&file, crate::runner::PREPARE_FAILURES, "step=\"admit\"", 1)?;
        let text = fs::read_to_string(&file)?;
        assert!(text.contains("exec_pool_prepare_failures_total{step=\"exec-pool-clone\"} 2\n"));
        assert!(text.contains("exec_pool_prepare_failures_total{step=\"admit\"} 1\n"));
        assert!(text.contains("# TYPE exec_pool_prepare_failures_total counter\n"));
        let bare = dir.join("b.prom");
        bump(
            &bare,
            crate::runner::PARK_PUSH_FAILURES,
            "slot=\"pool1\"",
            1,
        )?;
        bump(
            &bare,
            crate::runner::PARK_PUSH_FAILURES,
            "slot=\"pool1\"",
            2,
        )?;
        let text = fs::read_to_string(&bare)?;
        assert!(text.contains("# TYPE exec_pool_park_push_failures_total counter\n"));
        assert!(text.contains("exec_pool_park_push_failures_total{slot=\"pool1\"} 3\n"));
        fs::remove_dir_all(&dir)
    }
}
