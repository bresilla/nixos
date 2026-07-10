use std::collections::BTreeMap;
use std::io;
use std::path::Path;
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{
    Block, Clear, Gauge, Paragraph, Row, Table, TableState, Tabs, Wrap,
};
use ratatui::{Frame, Terminal};

use crate::install::preflight::PreflightStatus;
use crate::install::state::{DiskRole, InstallRole, InstallState, InstallStep};
use crate::install::storage::StorageLayout;
use crate::install::theme;
use crate::install::wizard::{
    DiskField, InstallWizard, TargetField, VolumeField, WizardCommand, WizardOutcome,
};
use crate::Result;

pub fn run(repo: &Path, execute: bool) -> Result<u8> {
    let mut wizard = InstallWizard::new(InstallState::draft());
    let mut last_disk_probe = None;
    let mut terminal = PreviewTerminal::enter()?;
    loop {
        terminal
            .terminal
            .draw(|frame| render(frame, &wizard))
            .map_err(|err| format!("failed to draw install wizard: {err}"))?;

        if !event::poll(Duration::from_millis(250))
            .map_err(|err| format!("failed to poll terminal input: {err}"))?
        {
            continue;
        }

        let Event::Key(key) =
            event::read().map_err(|err| format!("failed to read terminal input: {err}"))?
        else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }

        let Some(command) = command_from_key(key, &wizard) else {
            continue;
        };
        if wizard.state.current_step == InstallStep::Confirm && command == WizardCommand::Toggle {
            if !wizard
                .preflight
                .as_ref()
                .is_some_and(crate::install::preflight::PreflightReport::pass)
            {
                let report = crate::install::preflight::run(repo, &wizard.state);
                wizard.set_preflight(report);
                continue;
            }
        }
        match wizard.handle(command) {
            WizardOutcome::Continue => refresh_disks_if_needed(&mut wizard, &mut last_disk_probe),
            WizardOutcome::Quit => {
                terminal.leave()?;
                return Ok(0);
            }
            WizardOutcome::ReadyToInstall => {
                if execute {
                    if let Err(err) = wizard.commit_password() {
                        wizard.status = format!("password error: {err}");
                        continue;
                    }
                    // Stay in the TUI: run the install on a worker thread and
                    // render its live progress. Only leave the terminal after.
                    let code = run_install_screen(&mut terminal, repo, &wizard.state)?;
                    terminal.leave()?;
                    return Ok(code);
                }
                terminal.leave()?;
                crate::install::exec::prepare_generated(repo, &wizard.state)?;
                return Ok(0);
            }
        }
    }
}

/// Run the install on a worker thread and render its live progress inside the
/// TUI, draining reporter events each frame. Returns the install exit code once
/// the run finishes and the user dismisses the screen.
fn run_install_screen(
    terminal: &mut PreviewTerminal,
    repo: &Path,
    state: &InstallState,
) -> Result<u8> {
    let mut run = crate::install::progress::InstallRun::spawn(repo.to_path_buf(), state.clone());

    loop {
        run.pump();
        let elapsed = run.elapsed().as_secs();
        terminal
            .terminal
            .draw(|frame| render_progress(frame, &run.state, elapsed))
            .map_err(|err| format!("failed to draw install progress: {err}"))?;

        if event::poll(Duration::from_millis(120))
            .map_err(|err| format!("failed to poll terminal input: {err}"))?
        {
            if let Event::Key(key) =
                event::read().map_err(|err| format!("failed to read terminal input: {err}"))?
            {
                if key.kind == KeyEventKind::Press && run.is_finished() {
                    // Only q / Esc / Enter dismiss, and only once finished — the
                    // install itself is never interrupted mid-flight from here.
                    if matches!(
                        key.code,
                        KeyCode::Char('q') | KeyCode::Esc | KeyCode::Enter
                    ) {
                        return Ok(if run.state.failed { 1 } else { 0 });
                    }
                }
            }
        }
    }
}

fn render_progress(
    frame: &mut Frame<'_>,
    progress: &crate::install::progress::ProgressState,
    elapsed: u64,
) {
    use crate::install::progress::StepStatus;

    let area = frame.area();
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3), // gauge
            Constraint::Min(6),    // steps + output
            Constraint::Length(3), // footer
        ])
        .split(area);

    let label = if progress.finished {
        progress
            .summary
            .clone()
            .unwrap_or_else(|| "done".to_string())
    } else {
        format!(
            "{} — step {}/{}",
            if progress.phase.is_empty() {
                "installing"
            } else {
                progress.phase.as_str()
            },
            progress.completed_steps(),
            progress.total.max(1),
        )
    };
    let gauge_color = if progress.failed {
        theme::RED
    } else if progress.finished {
        theme::GREEN
    } else {
        theme::ACCENT
    };
    frame.render_widget(
        Gauge::default()
            .block(panel_titled(format!("install · {elapsed}s")))
            .gauge_style(Style::default().fg(gauge_color))
            .ratio(progress.ratio())
            .label(label),
        rows[0],
    );

    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(38), Constraint::Percentage(62)])
        .split(rows[1]);

    // Step list: two-line cards (name + status word).
    let step_rows: Vec<Row> = progress
        .steps
        .iter()
        .enumerate()
        .map(|(index, step)| {
            let (icon, color, word) = match step.status {
                StepStatus::Pending => ("○", theme::MUTED, "pending"),
                StepStatus::Running => ("▶", theme::ACCENT, "running"),
                StepStatus::Done => ("✓", theme::GREEN, "done"),
                StepStatus::Failed => ("✗", theme::RED, "failed"),
                StepStatus::Refused => ("⊘", theme::YELLOW, "refused"),
            };
            let mut name = theme::primary(step.name.clone());
            if Some(index) == progress.running_index {
                name = name.patch_style(Style::default().fg(theme::TEXT));
            }
            let detail = match step.millis {
                Some(ms) => format!("{word} · {:.1}s", ms as f64 / 1000.0),
                None => word.to_string(),
            };
            Row::new(vec![
                theme::cell1(Span::styled(icon, Style::default().fg(color))),
                theme::cell2(name, Span::styled(detail, Style::default().fg(color))),
            ])
            .height(2)
        })
        .collect();
    frame.render_widget(
        Table::new(
            step_rows,
            [Constraint::Length(3), Constraint::Min(10)],
        )
        .block(panel("steps")),
        columns[0],
    );

    // Output pane: last N lines, auto-scrolled to the tail.
    let output_area = columns[1];
    let visible = output_area.height.saturating_sub(2) as usize;
    let start = progress.output.len().saturating_sub(visible.max(1));
    let output_lines: Vec<Line> = progress.output[start..]
        .iter()
        .map(|line| {
            let color = if line.starts_with("! ") {
                theme::RED
            } else if line.starts_with('$') {
                theme::ACCENT
            } else if line.starts_with('•') {
                theme::MUTED
            } else {
                theme::SUBTEXT
            };
            Line::from(Span::styled(line.clone(), Style::default().fg(color)))
        })
        .collect();
    frame.render_widget(
        Paragraph::new(output_lines)
            .block(panel("output"))
            .wrap(Wrap { trim: false }),
        output_area,
    );

    // Footer.
    let footer = if progress.finished {
        Line::from(vec![
            Span::styled(
                if progress.failed { " FAILED " } else { " DONE " },
                Style::default()
                    .fg(theme::SURFACE_LO)
                    .bg(if progress.failed { theme::RED } else { theme::GREEN })
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw("  "),
            Span::styled(
                progress.summary.clone().unwrap_or_default(),
                theme::dim(),
            ),
        ])
    } else {
        Line::from(vec![
            Span::styled("● ", Style::default().fg(theme::PEACH)),
            Span::styled(
                "installing — do not power off the target",
                Style::default().fg(theme::YELLOW),
            ),
        ])
    };
    let hint = if progress.finished {
        Line::from([theme::chip("q", "exit"), theme::chip("↵", "exit")].concat()).right_aligned()
    } else {
        Line::from(Span::styled(" running… ", theme::dim())).right_aligned()
    };
    frame.render_widget(
        Paragraph::new(footer).block(theme::panel_bare().title(hint)),
        rows[2],
    );
}

fn refresh_disks_if_needed(wizard: &mut InstallWizard, last_probe: &mut Option<String>) {
    if wizard.state.current_step != InstallStep::Disks {
        return;
    }

    let probe_key = format!("{}:{}", wizard.state.scope.title(), wizard.state.remote);
    if last_probe.as_deref() == Some(&probe_key) {
        return;
    }
    *last_probe = Some(probe_key);

    // Full facts-based introspection for both scopes: native locally, a single
    // SSH round trip remotely (no agent bootstrap needed). Carries partition and
    // LVM contents so the picker shows what each disk currently holds.
    let facts = match wizard.state.scope {
        crate::install::state::InstallScope::Local => crate::facts::collect(),
        crate::install::state::InstallScope::Remote => {
            match crate::facts::collect_over_ssh(&wizard.state.remote) {
                Ok(facts) => facts,
                Err(err) => {
                    wizard.status = format!("disk discovery failed; edit manually: {err}");
                    return;
                }
            }
        }
    };

    let discovered = crate::facts::disk_choices(&facts);
    if discovered.is_empty() {
        wizard.status = "disk discovery found no disks; edit manually".to_string();
        return;
    }
    let count = discovered.len();
    let contents = facts
        .disks
        .iter()
        .map(|disk| format!("{}: {}", disk.path, disk.content_summary()))
        .collect::<Vec<_>>()
        .join("; ");
    wizard.state.discovered_disks = discovered;
    sync_selected_disks_after_discovery(&mut wizard.state);
    wizard.selected_disk = wizard
        .selected_disk
        .min(wizard.state.discovered_disks.len().saturating_sub(1));
    wizard.status = format!("discovered {count} disk(s) — {contents}");
    wizard.target_facts = Some(facts);
}

fn sync_selected_disks_after_discovery(state: &mut InstallState) {
    if state.discovered_disks.is_empty() {
        return;
    }

    state.disks.retain(|selected| {
        state
            .discovered_disks
            .iter()
            .any(|disk| disk.path == selected.path)
    });

    if state.disks.is_empty() {
        if let Some(first) = state.discovered_disks.first() {
            state.disks.push(first.clone());
            state
                .disk_roles
                .insert(first.path.clone(), DiskRole::System);
        }
    }
    state.normalize_disk_roles();
}

pub fn render(frame: &mut Frame<'_>, wizard: &InstallWizard) {
    let state = &wizard.state;
    let area = frame.area();
    frame.render_widget(Clear, area);

    let shell = full_screen(area);
    let secrets = if state.secrets_ready {
        Span::styled("● ", Style::default().fg(theme::GREEN))
    } else {
        Span::styled("○ ", Style::default().fg(theme::RED))
    };
    let outer = theme::panel_bare()
        .title(Line::from(vec![
            Span::styled(" ⬢ ", Style::default().fg(theme::ACCENT)),
            Span::styled("nox ", theme::title()),
            Span::styled("installer ", theme::dim()),
        ]))
        .title(
            Line::from(vec![
                secrets,
                Span::styled(
                    format!("{} · {} ", state.hostname, state.role.title()),
                    theme::dim(),
                ),
            ])
            .right_aligned(),
        );
    frame.render_widget(outer, shell);

    let inner = shell.inner(ratatui::layout::Margin {
        horizontal: 2,
        vertical: 1,
    });
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Length(3),
            Constraint::Min(12),
            Constraint::Length(3),
        ])
        .split(inner);

    render_header(frame, rows[0], wizard);
    render_step_tabs(frame, rows[1], state);
    render_body(frame, rows[2], wizard);
    render_footer(frame, rows[3], wizard);
}

fn command_from_key(key: KeyEvent, wizard: &InstallWizard) -> Option<WizardCommand> {
    if key.modifiers.contains(KeyModifiers::CONTROL) && matches!(key.code, KeyCode::Char('c')) {
        return Some(WizardCommand::Quit);
    }

    if wizard.state.current_step == InstallStep::Target {
        return match key.code {
            KeyCode::Esc => Some(WizardCommand::Back),
            KeyCode::Enter => Some(WizardCommand::Next),
            KeyCode::Backspace => Some(WizardCommand::Backspace),
            KeyCode::Char(' ') if wizard.target_field == TargetField::Scope => {
                Some(WizardCommand::Toggle)
            }
            KeyCode::Char('+') | KeyCode::Char('=') => Some(WizardCommand::Increase),
            KeyCode::Char('-') => Some(WizardCommand::Decrease),
            KeyCode::Tab | KeyCode::Right | KeyCode::Down => Some(WizardCommand::SelectNext),
            KeyCode::BackTab | KeyCode::Left | KeyCode::Up => Some(WizardCommand::SelectPrevious),
            KeyCode::Char(ch) => Some(WizardCommand::Insert(ch)),
            _ => None,
        };
    }

    if wizard.state.current_step == InstallStep::Confirm {
        let preflight_passed = wizard
            .preflight
            .as_ref()
            .is_some_and(crate::install::preflight::PreflightReport::pass);
        return match key.code {
            KeyCode::Esc => Some(WizardCommand::Back),
            KeyCode::Enter => Some(WizardCommand::Next),
            KeyCode::Backspace => Some(WizardCommand::Backspace),
            KeyCode::Char(' ') if !preflight_passed => Some(WizardCommand::Toggle),
            KeyCode::Char(ch) if preflight_passed => Some(WizardCommand::Insert(ch)),
            _ => None,
        };
    }

    if wizard.state.current_step == InstallStep::Disks {
        return match key.code {
            KeyCode::Esc => Some(WizardCommand::Back),
            KeyCode::Enter => Some(WizardCommand::Next),
            KeyCode::Char('q') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                Some(WizardCommand::Quit)
            }
            KeyCode::Char('q') => Some(WizardCommand::Quit),
            KeyCode::Char(' ') => Some(WizardCommand::Toggle),
            KeyCode::Backspace => Some(WizardCommand::Backspace),
            KeyCode::Char('+') | KeyCode::Char('=') => Some(WizardCommand::Increase),
            KeyCode::Char('-') => Some(WizardCommand::Decrease),
            KeyCode::Up | KeyCode::Char('k') => Some(WizardCommand::SelectDiskPrevious),
            KeyCode::Down | KeyCode::Char('j') => Some(WizardCommand::SelectDiskNext),
            KeyCode::Left | KeyCode::Char('h') | KeyCode::BackTab => {
                Some(WizardCommand::SelectPrevious)
            }
            KeyCode::Right | KeyCode::Char('l') | KeyCode::Tab => Some(WizardCommand::SelectNext),
            KeyCode::Char(ch) => Some(WizardCommand::Insert(ch)),
            _ => None,
        };
    }

    match key.code {
        KeyCode::Esc => Some(WizardCommand::Back),
        KeyCode::Enter => Some(WizardCommand::Next),
        KeyCode::Char('q') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            Some(WizardCommand::Quit)
        }
        KeyCode::Char('q') => Some(WizardCommand::Quit),
        KeyCode::Char(' ') => Some(WizardCommand::Toggle),
        KeyCode::Backspace => Some(WizardCommand::Backspace),
        KeyCode::Char('+') | KeyCode::Char('=') => Some(WizardCommand::Increase),
        KeyCode::Char('-') => Some(WizardCommand::Decrease),
        KeyCode::Left | KeyCode::Char('h') | KeyCode::Up | KeyCode::Char('k') => {
            Some(WizardCommand::SelectPrevious)
        }
        KeyCode::Right | KeyCode::Char('l') | KeyCode::Down | KeyCode::Char('j') => {
            Some(WizardCommand::SelectNext)
        }
        KeyCode::Tab => Some(WizardCommand::SelectNext),
        KeyCode::BackTab => Some(WizardCommand::SelectPrevious),
        _ => None,
    }
}

fn render_header(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let state = &wizard.state;
    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage(30),
            Constraint::Percentage(20),
            Constraint::Percentage(20),
            Constraint::Percentage(15),
            Constraint::Percentage(15),
        ])
        .split(area);

    render_stat(
        frame,
        columns[0],
        state.scope.title(),
        match state.scope {
            crate::install::state::InstallScope::Remote => &state.remote,
            crate::install::state::InstallScope::Local => &state.mountpoint,
        },
        theme::ACCENT,
        state.current_step == InstallStep::Target
            && matches!(
                wizard.target_field,
                TargetField::Scope | TargetField::Remote | TargetField::Mountpoint
            ),
    );
    render_stat(
        frame,
        columns[1],
        "host",
        &state.hostname,
        theme::GREEN,
        state.current_step == InstallStep::Target && wizard.target_field == TargetField::Hostname,
    );
    render_stat(
        frame,
        columns[2],
        "role",
        state.role.title(),
        theme::YELLOW,
        false,
    );
    render_stat(
        frame,
        columns[3],
        "ssh",
        if state.allow_ssh { "on" } else { "off" },
        if state.allow_ssh {
            theme::GREEN
        } else {
            theme::MUTED
        },
        state.current_step == InstallStep::Role,
    );
    render_stat(
        frame,
        columns[4],
        "secrets",
        if state.secrets_ready {
            "ready"
        } else {
            "locked"
        },
        if state.secrets_ready {
            theme::GREEN
        } else {
            theme::RED
        },
        false,
    );
}

fn render_stat(
    frame: &mut Frame<'_>,
    area: Rect,
    label: &str,
    value: &str,
    color: Color,
    focused: bool,
) {
    let text = Line::from(vec![
        Span::styled(
            if focused {
                format!("[{label}]")
            } else {
                label.to_string()
            },
            Style::default().fg(if focused {
                theme::TEXT
            } else {
                theme::MUTED
            }),
        ),
        Span::raw(" "),
        Span::styled(
            value,
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        ),
    ]);
    frame.render_widget(Paragraph::new(text).alignment(Alignment::Center), area);
}

const STEP_ICONS: [&str; 9] = ["◎", "▤", "▦", "☰", "◈", "⚿", "▷", "✔", "⬢"];

fn render_step_tabs(frame: &mut Frame<'_>, area: Rect, state: &InstallState) {
    let steps = InstallState::steps();
    let current = state.current_step_index();
    let titles: Vec<Line> = steps
        .iter()
        .enumerate()
        .map(|(index, step)| {
            let done = index < current;
            let icon = STEP_ICONS.get(index).copied().unwrap_or("•");
            let icon_color = if done { theme::GREEN } else { theme::ACCENT };
            Line::from(vec![
                Span::styled(format!("{icon} "), Style::default().fg(icon_color)),
                Span::styled(step.title(), theme::subtle()),
            ])
        })
        .collect();

    // No inner border here — the outer shell already frames the screen, and
    // dropping it reclaims the width the (many) step tabs need.
    let tabs = Tabs::new(titles)
        .select(current)
        .padding("", "")
        .highlight_style(
            Style::default()
                .fg(theme::TEXT)
                .bg(theme::ACCENT)
                .add_modifier(Modifier::BOLD),
        )
        .divider(Span::styled(" · ", theme::dim()));
    // Vertically center the single tab line within the 3-row slot.
    let inner = area.inner(ratatui::layout::Margin {
        horizontal: 1,
        vertical: 1,
    });
    frame.render_widget(tabs, inner);
}

fn render_body(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    if wizard.state.current_step == InstallStep::StoragePlan {
        render_storage_plan_review(frame, area, wizard);
        return;
    }

    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage(28),
            Constraint::Percentage(44),
            Constraint::Percentage(28),
        ])
        .split(area);

    render_disk_panel(frame, columns[0], wizard);
    if wizard.state.current_step == InstallStep::Pools {
        render_pool_panel(frame, columns[1], wizard);
    } else {
        render_volume_panel(frame, columns[1], wizard);
    }
    render_summary_panel(frame, columns[2], wizard);
}

fn render_storage_plan_review(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(5),
            Constraint::Min(10),
            Constraint::Length(3),
        ])
        .split(area);

    let target_lines = storage_plan_target_lines(&wizard.state);
    frame.render_widget(
        Paragraph::new(target_lines)
            .block(panel("storage plan"))
            .wrap(Wrap { trim: true }),
        rows[0],
    );

    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage(34),
            Constraint::Percentage(33),
            Constraint::Percentage(33),
        ])
        .split(rows[1]);

    frame.render_widget(
        Paragraph::new(storage_plan_pool_lines(&wizard.state))
            .block(panel("pools"))
            .wrap(Wrap { trim: true }),
        columns[0],
    );
    frame.render_widget(
        Paragraph::new(storage_plan_disk_and_volume_lines(&wizard.state))
            .block(panel("disks + logical volumes"))
            .wrap(Wrap { trim: true }),
        columns[1],
    );
    frame.render_widget(
        Paragraph::new(storage_plan_action_lines(&wizard.state, 128))
            .block(panel("actions"))
            .wrap(Wrap { trim: true }),
        columns[2],
    );

    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("enter", Style::default().fg(theme::ACCENT)),
            Span::raw(" continue  "),
            Span::styled("esc", Style::default().fg(theme::ACCENT)),
            Span::raw(" back  "),
            Span::styled(&wizard.status, Style::default().fg(theme::YELLOW)),
        ]))
        .alignment(Alignment::Center),
        rows[2],
    );
}

fn storage_plan_target_lines(state: &InstallState) -> Vec<Line<'static>> {
    vec![
        Line::from(vec![
            Span::styled("target ", Style::default().fg(theme::MUTED)),
            Span::styled(state.scope.title(), Style::default().fg(theme::ACCENT)),
            Span::raw(" "),
            Span::styled(
                match state.scope {
                    crate::install::state::InstallScope::Remote => state.remote.clone(),
                    crate::install::state::InstallScope::Local => state.mountpoint.clone(),
                },
                Style::default().fg(theme::TEXT),
            ),
            Span::raw("  "),
            Span::styled("host ", Style::default().fg(theme::MUTED)),
            Span::styled(state.hostname.clone(), Style::default().fg(theme::GREEN)),
            Span::raw("  "),
            Span::styled("user ", Style::default().fg(theme::MUTED)),
            Span::styled(
                state.install_user.clone(),
                Style::default().fg(theme::TEXT),
            ),
        ]),
        Line::from(vec![
            Span::styled("mode ", Style::default().fg(theme::MUTED)),
            Span::styled(
                state.storage_mode.title(),
                Style::default().fg(theme::TEXT),
            ),
            Span::raw("  "),
            Span::styled("overwrite ", Style::default().fg(theme::MUTED)),
            Span::styled(
                if state.overwrite_existing_storage {
                    "enabled"
                } else {
                    "disabled"
                },
                Style::default().fg(if state.overwrite_existing_storage {
                    theme::RED
                } else {
                    theme::MUTED
                }),
            ),
            Span::raw("  "),
            Span::styled("source ", Style::default().fg(theme::MUTED)),
            Span::styled(
                "generated/storage-plan.json",
                Style::default().fg(theme::BLUE),
            ),
        ]),
    ]
}

fn storage_plan_pool_lines(state: &InstallState) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    let (total_by_pool, used_by_pool) = pool_capacity_maps(state);

    for group in &state.volume_groups {
        let total = total_by_pool.get(&group.name).copied().unwrap_or(0);
        let used = used_by_pool.get(&group.name).copied().unwrap_or(0);
        let free = total.saturating_sub(used);
        let capacity_color = if total == 0 || used > total {
            theme::RED
        } else if free < 16 {
            theme::YELLOW
        } else {
            theme::GREEN
        };
        lines.push(Line::from(vec![
            Span::styled(
                group.name.clone(),
                Style::default()
                    .fg(theme::TEXT)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("  used={used}G total={total}G free={free}G"),
                Style::default().fg(capacity_color),
            ),
        ]));

        let disks = state
            .disks
            .iter()
            .filter(|disk| {
                state.disk_volume_group_for_path(&disk.path) == Some(group.name.as_str())
            })
            .map(|disk| disk.path.clone())
            .collect::<Vec<_>>();
        lines.push(Line::from(vec![
            Span::styled("  disks ", Style::default().fg(theme::MUTED)),
            Span::styled(
                if disks.is_empty() {
                    "-".to_string()
                } else {
                    disks.join(", ")
                },
                Style::default().fg(theme::BLUE),
            ),
        ]));

        let volumes = state
            .volumes
            .iter()
            .filter(|volume| state.volume_group_for_volume(&volume.name) == group.name)
            .map(|volume| volume.name.clone())
            .collect::<Vec<_>>();
        lines.push(Line::from(vec![
            Span::styled("  lvs   ", Style::default().fg(theme::MUTED)),
            Span::styled(
                if volumes.is_empty() {
                    "-".to_string()
                } else {
                    volumes.join(", ")
                },
                Style::default().fg(theme::GREEN),
            ),
        ]));
        lines.push(Line::raw(""));
    }

    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "no pools",
            Style::default().fg(theme::RED),
        )));
    }
    lines
}

fn storage_plan_disk_and_volume_lines(state: &InstallState) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(Span::styled(
        "disks",
        Style::default().fg(theme::MUTED),
    ))];

    for disk in state.visible_disks() {
        let role = state.disk_role_for_path(&disk.path);
        let pool = state.disk_volume_group_for_path(&disk.path).unwrap_or("-");
        lines.push(Line::from(vec![
            Span::styled(role.marker(), Style::default().fg(disk_role_color(role))),
            Span::raw(" "),
            Span::styled(disk.path.clone(), Style::default().fg(theme::TEXT)),
            Span::styled(
                format!(" {}G", disk.size_gib),
                Style::default().fg(theme::YELLOW),
            ),
            Span::styled(format!(" {pool}"), Style::default().fg(theme::BLUE)),
        ]));
    }

    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "logical volumes",
        Style::default().fg(theme::MUTED),
    )));
    for volume in &state.volumes {
        lines.push(Line::from(vec![
            Span::styled(
                format!("{:<5}", volume.name),
                Style::default()
                    .fg(theme::TEXT)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("{:<8}", volume.mountpoint.label()),
                Style::default().fg(theme::GREEN),
            ),
            Span::styled(
                state.volume_group_for_volume(&volume.name).to_string(),
                Style::default().fg(theme::BLUE),
            ),
            Span::styled(
                format!(" {}G", volume.size_gib),
                Style::default().fg(theme::YELLOW),
            ),
        ]));
    }

    lines
}

fn storage_plan_action_lines(state: &InstallState, limit: usize) -> Vec<Line<'static>> {
    let mut lines = Vec::new();

    if state.overwrite_existing_storage {
        match StorageLayout::from_state(state) {
            Ok(layout) => {
                for vg_name in layout.lvm_vg_names() {
                    lines.push(action_line(
                        "!",
                        &format!("remove existing VG {vg_name}"),
                        theme::RED,
                    ));
                }
            }
            Err(err) => {
                lines.push(Line::from(Span::styled(
                    format!("preview unavailable: {err}"),
                    Style::default().fg(theme::RED),
                )));
                return lines;
            }
        }
    }

    let layout = match StorageLayout::from_state(state) {
        Ok(layout) => layout,
        Err(err) => {
            lines.push(Line::from(Span::styled(
                format!("preview unavailable: {err}"),
                Style::default().fg(theme::RED),
            )));
            return lines;
        }
    };

    let actions = layout.actions();
    for action in actions.iter().take(limit) {
        lines.push(action_line(
            if action.destructive() { "!" } else { "-" },
            &action.label(),
            if action.destructive() {
                theme::RED
            } else {
                theme::MUTED
            },
        ));
    }
    if actions.len() > limit {
        lines.push(Line::from(Span::styled(
            format!("... {} more", actions.len() - limit),
            Style::default().fg(theme::MUTED),
        )));
    }
    lines
}

fn render_disk_panel(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let state = &wizard.state;
    let on_step = state.current_step == InstallStep::Disks;
    let visible_disks = state.visible_disks();

    // Highlight the focused field of the active row with a bracketed value.
    let field_val = |active: bool, field: DiskField, value: String| -> Span<'static> {
        if active && wizard.disk_field == field {
            Span::styled(format!("[{value}]"), Style::default().fg(theme::ACCENT))
        } else {
            Span::styled(value, theme::subtle())
        }
    };

    let rows = visible_disks
        .iter()
        .enumerate()
        .map(|(index, disk)| {
            let role = state.disk_role_for_path(&disk.path);
            let pool = state.disk_volume_group_for_path(&disk.path).unwrap_or("-");
            let active = on_step && index == wizard.selected_disk;

            let role_color = disk_role_color(role);
            // Column 0 (role): "[S] system" over the pool name.
            let role_top = if active && wizard.disk_field == DiskField::Role {
                Span::styled(
                    format!("{} {}", role.marker(), role.title()),
                    Style::default().fg(role_color).add_modifier(Modifier::BOLD),
                )
            } else {
                Span::styled(
                    format!("{} {}", role.marker(), role.title()),
                    Style::default().fg(role_color),
                )
            };
            let pool_span = if active && wizard.disk_field == DiskField::Pool {
                Span::styled(format!("pool [{pool}]"), Style::default().fg(theme::ACCENT))
            } else {
                Span::styled(format!("pool {pool}"), Style::default().fg(theme::BLUE))
            };

            // Column 1 (device): path over "size · model".
            let path_span = if active && wizard.disk_field == DiskField::Path {
                Span::styled(
                    format!("[{}]", disk.path),
                    theme::text().add_modifier(Modifier::BOLD),
                )
            } else {
                theme::primary(disk.path.clone())
            };
            let model = disk.model.as_deref().unwrap_or("disk");
            let size_span = field_val(active, DiskField::Size, format!("{}G", disk.size_gib));

            Row::new(vec![
                theme::cell2(role_top, pool_span),
                theme::cell2(
                    path_span,
                    Line::from(vec![
                        size_span,
                        Span::styled(format!(" · {model}"), theme::dim()),
                    ]),
                ),
            ])
            .height(2)
        })
        .collect::<Vec<_>>();

    let title = if on_step && wizard.disk_field == DiskField::Overwrite {
        if state.overwrite_existing_storage {
            "disks · overwrite ON"
        } else {
            "disks · overwrite off"
        }
    } else {
        "disks · roles: S P D R"
    };

    let table = Table::new(rows, [Constraint::Length(12), Constraint::Min(14)])
        .block(panel(title))
        .row_highlight_style(theme::selected_row())
        .highlight_symbol(ratatui::text::Text::from(vec![
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
        ]));

    if on_step && !visible_disks.is_empty() {
        let mut ts = TableState::default();
        ts.select(Some(wizard.selected_disk.min(visible_disks.len() - 1)));
        frame.render_stateful_widget(table, area, &mut ts);
    } else {
        frame.render_widget(table, area);
    }
}

fn disk_role_color(role: DiskRole) -> Color {
    match role {
        DiskRole::System | DiskRole::PoolMember => theme::GREEN,
        DiskRole::Data => theme::YELLOW,
        DiskRole::Reserve => theme::BLUE,
        DiskRole::Ignore => theme::MUTED,
    }
}

fn render_volume_panel(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let state = &wizard.state;
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(4)])
        .split(area);

    let label = format!(
        "{}G used / {}G total",
        state.used_gib(),
        state.total_disk_gib()
    );
    let gauge = Gauge::default()
        .block(panel("capacity"))
        .gauge_style(
            Style::default()
                .fg(theme::ACCENT)
                .bg(theme::SURFACE_LO)
                .add_modifier(Modifier::BOLD),
        )
        .label(label)
        .ratio(state.used_ratio());
    frame.render_widget(gauge, rows[0]);

    let on_step = state.current_step == InstallStep::Volumes;
    let bracket = |active: bool, field: VolumeField, value: String, color: Color| -> Span<'static> {
        if active && wizard.volume_field == field {
            Span::styled(format!("[{value}]"), Style::default().fg(theme::ACCENT))
        } else {
            Span::styled(value, Style::default().fg(color))
        }
    };

    let table_rows = state
        .volumes
        .iter()
        .enumerate()
        .map(|(index, volume)| {
            let mount = volume.mountpoint.label();
            let pool = state.volume_group_for_volume(&volume.name);
            let active = on_step && index == wizard.selected_volume;

            let name = if active && wizard.volume_field == VolumeField::Name {
                Span::styled(
                    format!("[{}]", volume.name),
                    theme::text().add_modifier(Modifier::BOLD),
                )
            } else {
                theme::primary(volume.name.clone())
            };
            Row::new(vec![
                theme::cell2(
                    name,
                    bracket(active, VolumeField::Mountpoint, mount.to_string(), theme::GREEN),
                ),
                theme::cell2(
                    bracket(active, VolumeField::Size, format!("{}G", volume.size_gib), theme::YELLOW),
                    bracket(active, VolumeField::Pool, format!("on {pool}"), theme::BLUE),
                ),
            ])
            .height(2)
        })
        .collect::<Vec<_>>();

    let table = Table::new(table_rows, [Constraint::Min(14), Constraint::Length(14)])
        .block(panel("volumes"))
        .row_highlight_style(theme::selected_row())
        .highlight_symbol(ratatui::text::Text::from(vec![
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
        ]));

    if on_step && !state.volumes.is_empty() {
        let mut ts = TableState::default();
        ts.select(Some(wizard.selected_volume.min(state.volumes.len() - 1)));
        frame.render_stateful_widget(table, rows[1], &mut ts);
    } else {
        frame.render_widget(table, rows[1]);
    }
}

fn render_pool_panel(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let state = &wizard.state;
    let (total_by_pool, used_by_pool) = pool_capacity_maps(state);
    let items = state
        .volume_groups
        .iter()
        .enumerate()
        .map(|(_index, group)| {
            let total = total_by_pool.get(&group.name).copied().unwrap_or(0);
            let used = used_by_pool.get(&group.name).copied().unwrap_or(0);
            let free = total.saturating_sub(used);
            let disks = state
                .disks
                .iter()
                .filter(|disk| {
                    state.disk_volume_group_for_path(&disk.path) == Some(group.name.as_str())
                })
                .map(|disk| disk.path.rsplit('/').next().unwrap_or(&disk.path))
                .collect::<Vec<_>>()
                .join("+");
            let volumes = state
                .volumes
                .iter()
                .filter(|volume| state.volume_group_for_volume(&volume.name) == group.name)
                .map(|volume| volume.name.as_str())
                .collect::<Vec<_>>()
                .join(",");
            let capacity_color = if total == 0 || used > total {
                theme::RED
            } else if free < 16 {
                theme::YELLOW
            } else {
                theme::GREEN
            };
            Row::new(vec![
                theme::cell2(
                    theme::primary(group.name.clone()),
                    Span::styled(
                        format!("{used}G/{total}G"),
                        Style::default().fg(capacity_color).add_modifier(Modifier::BOLD),
                    ),
                ),
                theme::cell2(
                    Line::from(vec![
                        Span::styled("disks ", theme::dim()),
                        Span::styled(
                            if disks.is_empty() { "-".to_string() } else { disks },
                            Style::default().fg(theme::BLUE),
                        ),
                    ]),
                    Line::from(vec![
                        Span::styled("vols ", theme::dim()),
                        Span::styled(
                            if volumes.is_empty() { "-".to_string() } else { volumes },
                            Style::default().fg(theme::GREEN),
                        ),
                    ]),
                ),
            ])
            .height(2)
        })
        .collect::<Vec<_>>();

    let _ = wizard.selected_pool; // selection highlight below
    let table = Table::new(items, [Constraint::Length(14), Constraint::Min(16)])
        .block(panel("pools"))
        .row_highlight_style(theme::selected_row())
        .highlight_symbol(ratatui::text::Text::from(vec![
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
        ]));

    if state.current_step == InstallStep::Pools && !state.volume_groups.is_empty() {
        let mut ts = TableState::default();
        ts.select(Some(wizard.selected_pool.min(state.volume_groups.len() - 1)));
        frame.render_stateful_widget(table, area, &mut ts);
    } else {
        frame.render_widget(table, area);
    }
}

fn render_summary_panel(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let state = &wizard.state;
    let dotfiles = state.dotfiles_repo.as_deref().unwrap_or("none");
    let roles = InstallRole::all()
        .iter()
        .map(|role| role.title())
        .collect::<Vec<_>>()
        .join("/");
    let mut text = vec![
        Line::from(vec![
            Span::styled("free", Style::default().fg(theme::MUTED)),
            Span::raw(" "),
            Span::styled(
                format!("{}G", state.free_gib()),
                Style::default()
                    .fg(theme::GREEN)
                    .add_modifier(Modifier::BOLD),
            ),
        ]),
        Line::raw(""),
        Line::from(Span::styled(
            "dotfiles",
            Style::default().fg(theme::MUTED),
        )),
        Line::from(Span::styled(dotfiles, Style::default().fg(theme::TEXT))),
        Line::raw(""),
        Line::from(vec![
            Span::styled("roles", Style::default().fg(theme::MUTED)),
            Span::raw(" "),
            Span::styled(roles, Style::default().fg(theme::TEXT)),
        ]),
        Line::from(vec![
            Span::styled("storage", Style::default().fg(theme::MUTED)),
            Span::raw(" "),
            Span::styled(
                state.storage_mode.title(),
                Style::default().fg(
                    if state.current_step == InstallStep::Disks
                        && wizard.disk_field == DiskField::Mode
                    {
                        theme::ACCENT
                    } else {
                        theme::TEXT
                    },
                ),
            ),
        ]),
        Line::from(vec![
            Span::styled("filesystem", Style::default().fg(theme::MUTED)),
            Span::raw(" "),
            Span::styled(
                state.filesystem.title(),
                Style::default().fg(
                    if state.current_step == InstallStep::Disks
                        && wizard.disk_field == DiskField::Filesystem
                    {
                        theme::ACCENT
                    } else {
                        theme::TEXT
                    },
                ),
            ),
        ]),
        Line::from(vec![
            Span::styled("encrypt", Style::default().fg(theme::MUTED)),
            Span::raw(" "),
            Span::styled(
                if state.encrypt { "luks" } else { "off" },
                Style::default().fg(
                    if state.current_step == InstallStep::Disks
                        && wizard.disk_field == DiskField::Encrypt
                    {
                        theme::ACCENT
                    } else if state.encrypt {
                        theme::YELLOW
                    } else {
                        theme::MUTED
                    },
                ),
            ),
        ]),
        Line::from(vec![
            Span::styled("ssh", Style::default().fg(theme::MUTED)),
            Span::raw(" "),
            Span::styled(
                if state.allow_ssh {
                    "enabled"
                } else {
                    "disabled"
                },
                Style::default().fg(if state.allow_ssh {
                    theme::GREEN
                } else {
                    theme::MUTED
                }),
            ),
        ]),
        Line::from(vec![
            Span::styled("overwrite", Style::default().fg(theme::MUTED)),
            Span::raw(" "),
            Span::styled(
                if state.overwrite_existing_storage {
                    "enabled"
                } else {
                    "disabled"
                },
                Style::default().fg(if state.overwrite_existing_storage {
                    theme::RED
                } else {
                    theme::MUTED
                }),
            ),
        ]),
        Line::from(vec![
            Span::styled("user", Style::default().fg(theme::MUTED)),
            Span::raw(" "),
            Span::styled(&state.install_user, Style::default().fg(theme::TEXT)),
        ]),
        Line::from(vec![
            Span::styled("password", Style::default().fg(theme::MUTED)),
            Span::raw(" "),
            if wizard.password.is_empty() {
                Span::styled("(none — passwordless)", Style::default().fg(theme::YELLOW))
            } else {
                Span::styled(
                    "•".repeat(wizard.password.chars().count().min(24)),
                    Style::default().fg(theme::TEXT),
                )
            },
        ]),
        Line::from(vec![
            Span::styled("confirm", Style::default().fg(theme::MUTED)),
            Span::raw(" "),
            Span::styled(
                if wizard.confirm_armed {
                    "armed"
                } else {
                    "locked"
                },
                Style::default().fg(if wizard.confirm_armed {
                    theme::RED
                } else {
                    theme::GREEN
                }),
            ),
        ]),
        Line::raw(""),
        Line::from(Span::styled("pools", Style::default().fg(theme::MUTED))),
    ];
    text.extend(pool_summary_lines(state));
    text.extend(storage_action_preview_lines(state, 8));
    text.extend([
        Line::raw(""),
        Line::from(Span::styled(
            &wizard.status,
            Style::default().fg(theme::YELLOW),
        )),
    ]);
    let text = if state.current_step == InstallStep::Confirm {
        confirm_summary_lines(wizard, text)
    } else {
        text
    };
    frame.render_widget(
        Paragraph::new(text)
            .block(panel("summary"))
            .wrap(Wrap { trim: true }),
        area,
    );
}

fn pool_summary_lines(state: &InstallState) -> Vec<Line<'static>> {
    let (total_by_pool, used_by_pool) = pool_capacity_maps(state);

    state
        .volume_groups
        .iter()
        .map(|group| {
            let total = total_by_pool.get(&group.name).copied().unwrap_or(0);
            let used = used_by_pool.get(&group.name).copied().unwrap_or(0);
            let free = total.saturating_sub(used);
            let color = if total == 0 || used > total {
                theme::RED
            } else if free < 16 {
                theme::YELLOW
            } else {
                theme::GREEN
            };
            Line::from(vec![
                Span::styled(
                    format!("{:<8}", group.name),
                    Style::default().fg(theme::TEXT),
                ),
                Span::styled(
                    format!("{used}G/{total}G"),
                    Style::default().fg(color).add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!(" free {free}G"),
                    Style::default().fg(theme::MUTED),
                ),
            ])
        })
        .collect()
}

fn pool_capacity_maps(state: &InstallState) -> (BTreeMap<String, u64>, BTreeMap<String, u64>) {
    let mut total_by_pool = BTreeMap::<String, u64>::new();
    for disk in &state.disks {
        let Some(pool) = state.disk_volume_group_for_path(&disk.path) else {
            continue;
        };
        *total_by_pool.entry(pool.to_string()).or_default() += disk.size_gib;
    }

    let mut used_by_pool = BTreeMap::<String, u64>::new();
    for volume in &state.volumes {
        let pool = state.volume_group_for_volume(&volume.name);
        *used_by_pool.entry(pool.to_string()).or_default() += volume.size_gib;
    }

    (total_by_pool, used_by_pool)
}

fn storage_action_preview_lines(state: &InstallState, limit: usize) -> Vec<Line<'static>> {
    let mut lines = vec![
        Line::raw(""),
        Line::from(Span::styled(
            "storage actions",
            Style::default().fg(theme::MUTED),
        )),
    ];

    if state.overwrite_existing_storage {
        match StorageLayout::from_state(state) {
            Ok(layout) => {
                for vg_name in layout.lvm_vg_names() {
                    lines.push(action_line("remove existing VG", &vg_name, theme::RED));
                }
            }
            Err(err) => {
                lines.push(Line::from(Span::styled(
                    format!("preview unavailable: {err}"),
                    Style::default().fg(theme::RED),
                )));
                return lines;
            }
        }
    }

    let layout = match StorageLayout::from_state(state) {
        Ok(layout) => layout,
        Err(err) => {
            lines.push(Line::from(Span::styled(
                format!("preview unavailable: {err}"),
                Style::default().fg(theme::RED),
            )));
            return lines;
        }
    };
    let actions = layout.actions();
    for action in actions.iter().take(limit) {
        lines.push(action_line(
            if action.destructive() { "!" } else { "-" },
            &action.label(),
            if action.destructive() {
                theme::RED
            } else {
                theme::MUTED
            },
        ));
    }
    if actions.len() > limit {
        lines.push(Line::from(Span::styled(
            format!("... {} more", actions.len() - limit),
            Style::default().fg(theme::MUTED),
        )));
    }
    lines
}

fn action_line(prefix: &str, text: &str, color: Color) -> Line<'static> {
    Line::from(vec![
        Span::styled(format!("{prefix:<3}"), Style::default().fg(color)),
        Span::styled(text.to_string(), Style::default().fg(theme::TEXT)),
    ])
}

fn confirm_summary_lines<'a>(wizard: &'a InstallWizard, mut lines: Vec<Line<'a>>) -> Vec<Line<'a>> {
    let confirmation = wizard.confirmation();
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "destructive confirmation",
        Style::default().fg(theme::MUTED),
    )));
    lines.push(Line::from(vec![
        Span::styled("target ", Style::default().fg(theme::MUTED)),
        Span::styled(
            confirmation.target.clone(),
            Style::default().fg(theme::TEXT),
        ),
    ]));
    lines.push(Line::from(vec![
        Span::styled("disks  ", Style::default().fg(theme::MUTED)),
        Span::styled(confirmation.disk_summary(), Style::default().fg(theme::RED)),
    ]));
    lines.extend(storage_action_preview_lines(&wizard.state, 24));

    if let Some(facts) = &wizard.target_facts {
        lines.push(Line::raw(""));
        lines.push(Line::from(Span::styled(
            "target",
            Style::default().fg(theme::MUTED),
        )));
        lines.push(Line::from(Span::styled(
            format!(
                "{} · {} · {}",
                facts.hostname.as_deref().unwrap_or("?"),
                if facts.efi { "UEFI" } else { "BIOS" },
                if facts.live_iso {
                    "installer ISO"
                } else {
                    "running system"
                },
            ),
            Style::default().fg(if facts.efi && facts.live_iso {
                theme::TEXT
            } else {
                theme::RED
            }),
        )));
        let plan = crate::facts::InstallAssessment {
            selected_disks: wizard
                .state
                .disks
                .iter()
                .map(|disk| disk.path.clone())
                .collect(),
            planned_vgs: wizard
                .state
                .volume_groups
                .iter()
                .map(|group| group.name.clone())
                .collect(),
            planned_gib: wizard.state.used_gib(),
            overwrite: wizard.state.overwrite_existing_storage,
        };
        for insight in crate::facts::assess(facts, &plan) {
            let (marker, color) = match insight.severity {
                crate::facts::Severity::Critical => ("!!", theme::RED),
                crate::facts::Severity::Warning => ("! ", theme::YELLOW),
                crate::facts::Severity::Info => ("· ", theme::MUTED),
            };
            lines.push(Line::from(vec![
                Span::styled(marker, Style::default().fg(color)),
                Span::styled(insight.message, Style::default().fg(color)),
            ]));
        }
    }

    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "type exactly:",
        Style::default().fg(theme::MUTED),
    )));
    lines.push(Line::from(Span::styled(
        confirmation.phrase,
        Style::default().fg(theme::YELLOW),
    )));
    lines.push(Line::from(vec![
        Span::styled("input ", Style::default().fg(theme::MUTED)),
        Span::styled(
            if wizard.confirm_input.is_empty() {
                "<empty>"
            } else {
                &wizard.confirm_input
            },
            Style::default().fg(if wizard.confirm_armed {
                theme::GREEN
            } else {
                theme::TEXT
            }),
        ),
    ]));
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "preflight",
        Style::default().fg(theme::MUTED),
    )));
    match &wizard.preflight {
        Some(report) => {
            for check in &report.checks {
                let (marker, color) = match check.status {
                    PreflightStatus::Pass => ("ok", theme::GREEN),
                    PreflightStatus::Fail => ("fail", theme::RED),
                };
                lines.push(Line::from(vec![
                    Span::styled(format!("{marker:<4}"), Style::default().fg(color)),
                    Span::styled(check.name, Style::default().fg(theme::TEXT)),
                ]));
                lines.push(Line::from(Span::styled(
                    format!("  {}", check.detail),
                    Style::default().fg(theme::MUTED),
                )));
            }
        }
        None => lines.push(Line::from(Span::styled(
            "press space to run checks",
            Style::default().fg(theme::YELLOW),
        ))),
    }
    lines
}

fn render_footer(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    // Contextual key chips per step, plus a right-aligned step counter and the
    // live status line.
    let mut chips: Vec<Span> = Vec::new();
    chips.extend(theme::chip("↵", "next"));
    chips.extend(theme::chip("esc", "back"));
    match wizard.state.current_step {
        InstallStep::Target => {
            chips.extend(theme::chip("↹", "field"));
            chips.extend(theme::chip("␣", "scope"));
        }
        InstallStep::Disks => {
            chips.extend(theme::chip("↑↓", "disk"));
            chips.extend(theme::chip("←→", "field"));
            chips.extend(theme::chip("␣", "role"));
            chips.extend(theme::chip("+-", "size"));
        }
        InstallStep::Volumes | InstallStep::Pools => {
            chips.extend(theme::chip("↑↓", "select"));
            chips.extend(theme::chip("+-", "size"));
        }
        InstallStep::Confirm => {
            chips.extend(theme::chip("␣", "preflight"));
        }
        _ => {}
    }
    chips.extend(theme::chip("q", "quit"));

    let counter = Line::from(vec![Span::styled(
        format!(
            " step {}/{} ",
            wizard.state.current_step_index() + 1,
            InstallState::steps().len()
        ),
        theme::dim(),
    )])
    .right_aligned();

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Min(20), Constraint::Length(14)])
        .split(area);

    frame.render_widget(
        Paragraph::new(Line::from(chips)).block(theme::panel_bare()),
        cols[0],
    );
    frame.render_widget(
        Paragraph::new(counter).block(theme::panel_bare()),
        cols[1],
    );
}

fn panel(title: &str) -> Block<'static> {
    theme::panel(title)
}

fn panel_titled(title: String) -> Block<'static> {
    theme::panel(&title)
}

fn full_screen(area: Rect) -> Rect {
    let horizontal = if area.width >= 100 { 1 } else { 0 };
    let vertical = if area.height >= 30 { 1 } else { 0 };
    Rect {
        x: area.x + horizontal,
        y: area.y + vertical,
        width: area.width.saturating_sub(horizontal * 2),
        height: area.height.saturating_sub(vertical * 2),
    }
}

struct PreviewTerminal {
    terminal: Terminal<CrosstermBackend<io::Stdout>>,
    left: bool,
}

impl PreviewTerminal {
    fn enter() -> Result<Self> {
        enable_raw_mode().map_err(|err| format!("failed to enable raw mode: {err}"))?;
        let mut stdout = io::stdout();
        execute!(stdout, EnterAlternateScreen)
            .map_err(|err| format!("failed to enter alternate screen: {err}"))?;
        let terminal = Terminal::new(CrosstermBackend::new(stdout))
            .map_err(|err| format!("failed to create terminal: {err}"))?;
        Ok(Self {
            terminal,
            left: false,
        })
    }

    fn leave(&mut self) -> Result<()> {
        if self.left {
            return Ok(());
        }
        disable_raw_mode().map_err(|err| format!("failed to disable raw mode: {err}"))?;
        execute!(self.terminal.backend_mut(), LeaveAlternateScreen)
            .map_err(|err| format!("failed to leave alternate screen: {err}"))?;
        self.terminal
            .show_cursor()
            .map_err(|err| format!("failed to show cursor: {err}"))?;
        self.left = true;
        Ok(())
    }
}

impl Drop for PreviewTerminal {
    fn drop(&mut self) {
        if !self.left {
            let _ = disable_raw_mode();
            let _ = execute!(self.terminal.backend_mut(), LeaveAlternateScreen);
            let _ = self.terminal.show_cursor();
        }
    }
}

#[cfg(test)]
mod tests {
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    use super::{render, render_progress};
    use crate::install::state::{InstallState, InstallStep};
    use crate::install::wizard::InstallWizard;

    #[test]
    fn renders_install_preview_without_panic() {
        let backend = TestBackend::new(100, 32);
        let mut terminal = Terminal::new(backend).unwrap();
        let wizard = InstallWizard::new(InstallState::sample());

        terminal.draw(|frame| render(frame, &wizard)).unwrap();
    }

    #[test]
    fn renders_storage_plan_review_without_panic() {
        let backend = TestBackend::new(120, 36);
        let mut terminal = Terminal::new(backend).unwrap();
        let mut wizard = InstallWizard::new(InstallState::sample());
        wizard.state.current_step = InstallStep::StoragePlan;

        terminal.draw(|frame| render(frame, &wizard)).unwrap();
    }

    #[test]
    fn renders_progress_screen_without_panic() {
        use crate::report::{Event, Stream};
        let mut progress = crate::install::progress::ProgressState::default();
        progress.apply(Event::Phase {
            name: "execute".to_string(),
        });
        progress.apply(Event::StepStarted {
            index: 0,
            total: 3,
            name: "prepare target disk".to_string(),
            command: "nox-agent disk-prepare /dev/sda".to_string(),
            destructive: true,
        });
        progress.apply(Event::StepOutput {
            stream: Stream::Stdout,
            chunk: b"copying paths...\n".to_vec(),
        });
        progress.apply(Event::StepCompleted {
            index: 0,
            name: "prepare target disk".to_string(),
            status: 0,
            stdout: String::new(),
            stderr: String::new(),
            millis: 1500,
        });

        let backend = TestBackend::new(120, 36);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|frame| render_progress(frame, &progress, 12))
            .unwrap();

        // Finished/failed state also renders.
        progress.finished = true;
        progress.failed = true;
        progress.summary = Some("install failed: boom".to_string());
        terminal
            .draw(|frame| render_progress(frame, &progress, 30))
            .unwrap();
    }

    #[test]
    fn password_field_is_masked_in_summary() {
        let backend = TestBackend::new(100, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        let mut wizard = InstallWizard::new(InstallState::sample());
        wizard.password = "hunter2".to_string();

        terminal.draw(|frame| render(frame, &wizard)).unwrap();
        let buffer = terminal.backend().buffer().clone();
        let rendered: String = buffer.content().iter().map(|cell| cell.symbol()).collect();
        // The plaintext never appears; the mask bullet does.
        assert!(!rendered.contains("hunter2"));
        assert!(rendered.contains('•'));
    }
}
