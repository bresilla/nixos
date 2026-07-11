//! Guided installer TUI. One question per screen, walked linearly with a
//! prev/current/next breadcrumb — see [`crate::install::flow`] for the step
//! sequence and state transitions. Rendering here is pure over the flow, and
//! the live install progress screen is reused from [`crate::install::progress`].

use std::io;
use std::path::Path;
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Alignment, Constraint, Direction, Flex, Layout, Margin, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Clear, Gauge, Paragraph, Row, Table, TableState, Wrap};
use ratatui::{Frame, Terminal};

use crate::install::flow::{Flow, Step, StepKind};
use crate::install::preflight::PreflightStatus;
use crate::install::state::InstallState;
use crate::install::theme;
use crate::Result;

pub fn run(repo: &Path, execute: bool) -> Result<u8> {
    let mut flow = Flow::new(InstallState::draft());
    let mut terminal = PreviewTerminal::enter()?;

    loop {
        terminal
            .terminal
            .draw(|frame| render_flow(frame, &flow))
            .map_err(|err| format!("failed to draw installer: {err}"))?;

        if !event::poll(Duration::from_millis(200))
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

        handle_key(&mut flow, key, repo);

        if flow.quit {
            terminal.leave()?;
            return Ok(0);
        }
        if flow.done {
            if execute {
                if let Err(err) = flow.commit_password() {
                    flow.status = format!("password error: {err}");
                    flow.done = false;
                    continue;
                }
                let code = run_install_screen(&mut terminal, repo, &flow.state)?;
                terminal.leave()?;
                return Ok(code);
            }
            terminal.leave()?;
            crate::install::exec::prepare_generated(repo, &flow.state)?;
            return Ok(0);
        }
    }
}

fn handle_key(flow: &mut Flow, key: KeyEvent, repo: &Path) {
    if key.modifiers.contains(KeyModifiers::CONTROL) && matches!(key.code, KeyCode::Char('c')) {
        flow.quit = true;
        return;
    }

    let kind = flow.current().kind();
    let input_step = matches!(kind, StepKind::Text | StepKind::Password | StepKind::Confirm);

    match key.code {
        KeyCode::Esc => {
            if flow.pos == 0 {
                flow.quit = true;
            } else {
                flow.back();
            }
        }
        KeyCode::Enter => flow.advance(),
        KeyCode::Backspace => flow.backspace(),
        KeyCode::Up | KeyCode::Left | KeyCode::BackTab if !input_step => flow.select_prev(),
        KeyCode::Down | KeyCode::Right | KeyCode::Tab if !input_step => flow.select_next(),
        KeyCode::Char('k') if !input_step => flow.select_prev(),
        KeyCode::Char('j') if !input_step => flow.select_next(),
        KeyCode::Char(' ') if kind == StepKind::Review => flow.toggle(repo),
        KeyCode::Char('q') if !input_step => flow.quit = true,
        KeyCode::Char(ch) if input_step => flow.insert(ch),
        _ => {}
    }
}

// ── flow screen ─────────────────────────────────────────────────

fn render_flow(frame: &mut Frame<'_>, flow: &Flow) {
    let area = frame.area();
    frame.render_widget(Clear, area);

    let shell = full_screen(area);
    let scope = flow.state.scope.title();
    let target = match flow.state.scope {
        crate::install::state::InstallScope::Remote => flow.state.remote.clone(),
        crate::install::state::InstallScope::Local => "this machine".to_string(),
    };
    let outer = theme::panel_bare()
        .title(Line::from(vec![
            Span::styled(" ⬢ ", Style::default().fg(theme::ACCENT)),
            Span::styled("nox ", theme::title()),
            Span::styled("installer ", theme::dim()),
        ]))
        .title(
            Line::from(Span::styled(format!("{scope} · {target} "), theme::dim())).right_aligned(),
        );
    frame.render_widget(outer, shell);

    let inner = shell.inner(Margin {
        horizontal: 2,
        vertical: 1,
    });
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2), // breadcrumb
            Constraint::Min(6),    // question card
            Constraint::Length(3), // footer
        ])
        .split(inner);

    render_breadcrumb(frame, rows[0], flow);
    render_card(frame, rows[1], flow);
    render_flow_footer(frame, rows[2], flow);
}

fn render_breadcrumb(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let mut spans = Vec::new();
    if let Some(prev) = flow.prev_step() {
        spans.push(Span::styled(format!("{}  ", prev.name()), theme::dim()));
    }
    spans.push(Span::styled("‹ ", Style::default().fg(theme::ACCENT)));
    spans.push(Span::styled(
        flow.current().name().to_uppercase(),
        Style::default()
            .fg(theme::TEXT)
            .bg(theme::ACCENT)
            .add_modifier(Modifier::BOLD),
    ));
    spans.push(Span::styled(" ›", Style::default().fg(theme::ACCENT)));
    if let Some(next) = flow.next_step() {
        spans.push(Span::styled(format!("  {}", next.name()), theme::dim()));
    }

    let (n, total) = flow.step_number();
    let counter = Line::from(Span::styled(format!("step {n}/{total}"), theme::dim()));

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Min(10), Constraint::Length(12)])
        .split(area);
    frame.render_widget(
        Paragraph::new(Line::from(spans)).alignment(Alignment::Center),
        cols[0],
    );
    frame.render_widget(
        Paragraph::new(counter).alignment(Alignment::Right),
        cols[1],
    );
}

fn render_card(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    // A centered card so each question reads as a single focused prompt.
    let width = area.width.min(80);
    let [card] = Layout::horizontal([Constraint::Length(width)])
        .flex(Flex::Center)
        .areas(area);

    let step = flow.current();
    let header = vec![
        Line::from(""),
        Line::from(Span::styled(step.question(), theme::title())),
        Line::from(Span::styled(step.help(), theme::dim())),
        Line::from(""),
    ];

    let block = theme::panel(step.name());
    let inner = block.inner(card);
    frame.render_widget(block, card);

    let body = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(4), Constraint::Min(2)])
        .split(inner);
    frame.render_widget(Paragraph::new(header).wrap(Wrap { trim: true }), body[0]);

    match step.kind() {
        StepKind::Choice | StepKind::Disk => render_options(frame, body[1], flow),
        StepKind::Text | StepKind::Password => render_input(frame, body[1], flow),
        StepKind::Review => render_review(frame, body[1], flow),
        StepKind::Confirm => render_confirm(frame, body[1], flow),
    }
}

fn render_options(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let options = flow.options();
    if options.is_empty() {
        let msg = flow
            .disk_error
            .clone()
            .map(|err| format!("no disks: {err}"))
            .unwrap_or_else(|| "no options available".to_string());
        frame.render_widget(
            Paragraph::new(Span::styled(msg, Style::default().fg(theme::RED)))
                .wrap(Wrap { trim: true }),
            area,
        );
        return;
    }

    let rows: Vec<Row> = options
        .iter()
        .enumerate()
        .map(|(index, opt)| {
            let selected = index == flow.cursor;
            let label = if selected {
                Span::styled(
                    opt.label.clone(),
                    Style::default().fg(theme::TEXT).add_modifier(Modifier::BOLD),
                )
            } else {
                Span::styled(opt.label.clone(), theme::subtle())
            };
            Row::new(vec![theme::cell2(
                label,
                Span::styled(opt.desc.clone(), theme::dim()),
            )])
            .height(2)
        })
        .collect();

    let table = Table::new(rows, [Constraint::Percentage(100)])
        .row_highlight_style(theme::selected_row())
        .highlight_symbol(ratatui::text::Text::from(vec![
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
        ]));
    let mut ts = TableState::default();
    ts.select(Some(flow.cursor.min(options.len() - 1)));
    frame.render_stateful_widget(table, area, &mut ts);
}

fn render_input(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let masked = flow.current().kind() == StepKind::Password;
    let shown = if masked {
        "•".repeat(flow.password.chars().count())
    } else {
        flow.buffer.clone()
    };
    let value_empty = shown.is_empty();

    let field = Line::from(vec![
        Span::styled("❯ ", Style::default().fg(theme::ACCENT)),
        if value_empty {
            Span::styled(
                match flow.current() {
                    Step::Dotfiles => "(blank to skip)",
                    _ => "type here…",
                },
                theme::dim(),
            )
        } else {
            Span::styled(shown, Style::default().fg(theme::TEXT).add_modifier(Modifier::BOLD))
        },
        Span::styled("█", Style::default().fg(theme::ACCENT)),
    ]);

    let block = theme::panel_bare().border_style(Style::default().fg(theme::ACCENT));
    frame.render_widget(
        Paragraph::new(vec![Line::from(""), field]).block(block),
        area.inner(Margin {
            horizontal: 0,
            vertical: 0,
        }),
    );
}

fn render_review(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let state = &flow.state;
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(area);

    // Left: the plan summary.
    let disk = state
        .disks
        .first()
        .map(|d| format!("{} ({}G)", d.path, d.size_gib))
        .unwrap_or_else(|| "-".to_string());
    let kv = |k: &str, v: String, color| {
        Line::from(vec![
            Span::styled(format!("{k:<11}"), theme::dim()),
            Span::styled(v, Style::default().fg(color)),
        ])
    };
    let summary = vec![
        kv("scope", format!("{} {}", state.scope.title(), if state.scope == crate::install::state::InstallScope::Remote { state.remote.clone() } else { "this machine".into() }), theme::TEXT),
        kv("hostname", state.hostname.clone(), theme::TEXT),
        kv("user", state.install_user.clone(), theme::TEXT),
        kv("password", if flow.password.is_empty() { "none".into() } else { "set".into() }, if flow.password.is_empty() { theme::YELLOW } else { theme::GREEN }),
        kv("role", state.role.title().to_string(), theme::TEXT),
        kv("ssh", if state.allow_ssh { "enabled".into() } else { "disabled".into() }, if state.allow_ssh { theme::GREEN } else { theme::MUTED }),
        kv("disk", disk, theme::TEXT),
        kv("filesystem", state.filesystem.title().to_string(), theme::TEXT),
        kv("encrypt", if state.encrypt { "yes".into() } else { "no".into() }, if state.encrypt { theme::GREEN } else { theme::MUTED }),
        kv("overwrite", if state.overwrite_existing_storage { "wipe".into() } else { "keep".into() }, if state.overwrite_existing_storage { theme::RED } else { theme::MUTED }),
        kv("dotfiles", state.dotfiles_repo.clone().unwrap_or_else(|| "skip".into()), theme::SUBTEXT),
    ];
    frame.render_widget(
        Paragraph::new(summary)
            .block(panel("plan"))
            .wrap(Wrap { trim: true }),
        cols[0],
    );

    // Right: insights + preflight.
    let mut lines: Vec<Line> = Vec::new();
    if let Some(facts) = &flow.facts {
        let plan = crate::facts::InstallAssessment {
            selected_disks: state.disks.iter().map(|d| d.path.clone()).collect(),
            planned_vgs: state.volume_groups.iter().map(|g| g.name.clone()).collect(),
            planned_gib: state.used_gib(),
            overwrite: state.overwrite_existing_storage,
        };
        for insight in crate::facts::assess(facts, &plan) {
            let (marker, color) = match insight.severity {
                crate::facts::Severity::Critical => ("!!", theme::RED),
                crate::facts::Severity::Warning => ("! ", theme::YELLOW),
                crate::facts::Severity::Info => ("· ", theme::MUTED),
            };
            lines.push(Line::from(vec![
                Span::styled(format!("{marker} "), Style::default().fg(color)),
                Span::styled(insight.message.clone(), Style::default().fg(color)),
            ]));
        }
    }
    if !lines.is_empty() {
        lines.push(Line::from(""));
    }
    match &flow.preflight {
        Some(report) => {
            for check in &report.checks {
                let (marker, color) = match check.status {
                    PreflightStatus::Pass => ("✓", theme::GREEN),
                    PreflightStatus::Fail => ("✗", theme::RED),
                };
                lines.push(Line::from(vec![
                    Span::styled(format!("{marker} "), Style::default().fg(color)),
                    Span::styled(check.name, Style::default().fg(theme::TEXT)),
                    Span::styled(format!("  {}", check.detail), theme::dim()),
                ]));
            }
        }
        None => lines.push(Line::from(Span::styled(
            "press space to run preflight",
            Style::default().fg(theme::YELLOW),
        ))),
    }
    frame.render_widget(
        Paragraph::new(lines)
            .block(panel("checks"))
            .wrap(Wrap { trim: true }),
        cols[1],
    );
}

fn render_confirm(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let phrase = flow.confirm_phrase();
    let armed = flow.confirm_armed();
    let lines = vec![
        Line::from(Span::styled(
            "This erases the target disk. Type the phrase exactly:",
            Style::default().fg(theme::RED),
        )),
        Line::from(""),
        Line::from(Span::styled(phrase, Style::default().fg(theme::YELLOW).add_modifier(Modifier::BOLD))),
        Line::from(""),
        Line::from(vec![
            Span::styled("❯ ", Style::default().fg(theme::ACCENT)),
            Span::styled(
                flow.confirm_input.clone(),
                Style::default().fg(if armed { theme::GREEN } else { theme::TEXT }),
            ),
            Span::styled("█", Style::default().fg(theme::ACCENT)),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            if armed { "✓ armed — enter to install" } else { "locked" },
            Style::default().fg(if armed { theme::GREEN } else { theme::MUTED }),
        )),
    ];
    frame.render_widget(
        Paragraph::new(lines)
            .block(theme::panel_bare().border_style(Style::default().fg(theme::RED)))
            .wrap(Wrap { trim: true }),
        area,
    );
}

fn render_flow_footer(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let mut chips: Vec<Span> = Vec::new();
    match flow.current().kind() {
        StepKind::Choice | StepKind::Disk => {
            chips.extend(theme::chip("↑↓", "choose"));
            chips.extend(theme::chip("↵", "next"));
        }
        StepKind::Text | StepKind::Password => {
            chips.extend(theme::chip("type", "edit"));
            chips.extend(theme::chip("↵", "next"));
        }
        StepKind::Review => {
            chips.extend(theme::chip("␣", "preflight"));
            chips.extend(theme::chip("↵", "next"));
        }
        StepKind::Confirm => {
            chips.extend(theme::chip("type", "phrase"));
            chips.extend(theme::chip("↵", "install"));
        }
    }
    chips.extend(theme::chip("esc", if flow.pos == 0 { "quit" } else { "back" }));

    let status = if flow.status.is_empty() {
        Line::from(Span::styled(" ", theme::dim()))
    } else {
        Line::from(Span::styled(flow.status.clone(), Style::default().fg(theme::YELLOW)))
            .right_aligned()
    };

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Min(20), Constraint::Percentage(40)])
        .split(area);
    frame.render_widget(
        Paragraph::new(Line::from(chips)).block(theme::panel_bare()),
        cols[0],
    );
    frame.render_widget(
        Paragraph::new(status).block(theme::panel_bare()),
        cols[1],
    );
}

// ── live install progress ───────────────────────────────────────

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
            Constraint::Length(3),
            Constraint::Min(6),
            Constraint::Length(3),
        ])
        .split(area);

    let label = if progress.finished {
        progress.summary.clone().unwrap_or_else(|| "done".to_string())
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
        Table::new(step_rows, [Constraint::Length(3), Constraint::Min(10)]).block(panel("steps")),
        columns[0],
    );

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
            Span::styled(progress.summary.clone().unwrap_or_default(), theme::dim()),
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

// ── terminal plumbing ───────────────────────────────────────────

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

    use super::{render_flow, render_progress};
    use crate::install::flow::{Flow, Step};
    use crate::install::state::InstallState;

    fn draw(flow: &Flow) -> String {
        let mut terminal = Terminal::new(TestBackend::new(110, 34)).unwrap();
        terminal.draw(|frame| render_flow(frame, flow)).unwrap();
        let buf = terminal.backend().buffer().clone();
        buf.content().iter().map(|c| c.symbol()).collect()
    }

    #[test]
    fn renders_first_question_without_panic() {
        let flow = Flow::new(InstallState::draft());
        let text = draw(&flow);
        assert!(text.contains("Where do you want to install"));
        assert!(text.contains("local"));
        assert!(text.contains("remote"));
    }

    #[test]
    fn renders_breadcrumb_current_step() {
        let flow = Flow::new(InstallState::draft());
        let text = draw(&flow);
        assert!(text.contains("SCOPE"));
        assert!(text.contains("step 1/"));
    }

    #[test]
    fn password_step_masks_input() {
        let mut flow = Flow::new(InstallState::draft());
        // walk to the password step (local scope: scope->hostname->user->password)
        flow.cursor = 0;
        flow.advance();
        flow.buffer = "novo".into();
        flow.advance();
        flow.buffer = "bresilla".into();
        flow.advance();
        assert_eq!(flow.current(), Step::Password);
        flow.insert('s');
        flow.insert('e');
        flow.insert('c');
        let text = draw(&flow);
        assert!(!text.contains("sec"));
        assert!(text.contains('•'));
    }

    #[test]
    fn renders_progress_screen_without_panic() {
        use crate::report::{Event, Stream};
        let mut progress = crate::install::progress::ProgressState::default();
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

        let mut terminal = Terminal::new(TestBackend::new(120, 36)).unwrap();
        terminal
            .draw(|frame| render_progress(frame, &progress, 12))
            .unwrap();

        progress.finished = true;
        progress.failed = true;
        progress.summary = Some("install failed: boom".to_string());
        terminal
            .draw(|frame| render_progress(frame, &progress, 30))
            .unwrap();
    }
}
