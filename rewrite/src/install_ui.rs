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
use ratatui::widgets::{Block, BorderType, Borders, Clear, Gauge, List, ListItem, Paragraph, Wrap};
use ratatui::{Frame, Terminal};

use crate::install_disk;
use crate::install_exec;
use crate::install_preflight::{self, PreflightStatus};
use crate::install_state::{InstallRole, InstallState, InstallStep};
use crate::install_wizard::{
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
                .is_some_and(crate::install_preflight::PreflightReport::pass)
            {
                let report = install_preflight::run(repo, &wizard.state);
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
                terminal.leave()?;
                if execute {
                    return install_exec::run_confirmed(repo, &wizard.state);
                }
                install_exec::prepare_generated(repo, &wizard.state)?;
                return Ok(0);
            }
        }
    }
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

    match install_disk::discover(wizard.state.scope, &wizard.state.remote) {
        Ok(disks) => {
            let count = disks.len();
            wizard.state.disks = install_disk::choices_from_disks(&disks);
            wizard.status = format!("discovered {count} install disk(s)");
        }
        Err(err) => {
            wizard.status = format!("disk discovery failed; edit manually: {err}");
        }
    }
}

pub fn render(frame: &mut Frame<'_>, wizard: &InstallWizard) {
    let state = &wizard.state;
    let area = frame.area();
    frame.render_widget(Clear, area);

    let shell = full_screen(area);
    let outer = Block::default()
        .title(Line::from(vec![
            Span::styled(" nx ", Style::default().fg(Color::Black).bg(Color::Cyan)),
            Span::styled(" NixOS installer ", Style::default().fg(Color::White)),
        ]))
        .title_bottom(Line::from(" enter next  esc back  q quit ").alignment(Alignment::Right))
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(Color::DarkGray));
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
            .is_some_and(crate::install_preflight::PreflightReport::pass);
        return match key.code {
            KeyCode::Esc => Some(WizardCommand::Back),
            KeyCode::Enter => Some(WizardCommand::Next),
            KeyCode::Backspace => Some(WizardCommand::Backspace),
            KeyCode::Char(' ') if !preflight_passed => Some(WizardCommand::Toggle),
            KeyCode::Char(ch) if preflight_passed => Some(WizardCommand::Insert(ch)),
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
            Constraint::Percentage(34),
            Constraint::Percentage(22),
            Constraint::Percentage(22),
            Constraint::Percentage(22),
        ])
        .split(area);

    render_stat(
        frame,
        columns[0],
        state.scope.title(),
        match state.scope {
            crate::install_state::InstallScope::Remote => &state.remote,
            crate::install_state::InstallScope::Local => &state.mountpoint,
        },
        Color::Cyan,
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
        Color::Green,
        state.current_step == InstallStep::Target && wizard.target_field == TargetField::Hostname,
    );
    render_stat(
        frame,
        columns[2],
        "role",
        state.role.title(),
        Color::Yellow,
        false,
    );
    render_stat(
        frame,
        columns[3],
        "secrets",
        if state.secrets_ready {
            "ready"
        } else {
            "locked"
        },
        if state.secrets_ready {
            Color::Green
        } else {
            Color::Red
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
                Color::White
            } else {
                Color::DarkGray
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

fn render_step_tabs(frame: &mut Frame<'_>, area: Rect, state: &InstallState) {
    let steps = InstallState::steps();
    let constraints = vec![Constraint::Ratio(1, steps.len() as u32); steps.len()];
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints(constraints)
        .split(area);

    for (index, step) in steps.iter().enumerate() {
        let active = *step == state.current_step;
        let done = index < state.current_step_index();
        let marker = if active {
            ">"
        } else if done {
            "*"
        } else {
            "-"
        };
        let color = if active {
            Color::Cyan
        } else if done {
            Color::Green
        } else {
            Color::DarkGray
        };
        let line = Line::from(vec![
            Span::styled(
                marker,
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            ),
            Span::raw(" "),
            Span::styled(step.title(), Style::default().fg(color)),
        ]);
        frame.render_widget(
            Paragraph::new(line).alignment(Alignment::Center),
            chunks[index],
        );
    }
}

fn render_body(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage(28),
            Constraint::Percentage(44),
            Constraint::Percentage(28),
        ])
        .split(area);

    render_disk_panel(frame, columns[0], wizard);
    render_volume_panel(frame, columns[1], wizard);
    render_summary_panel(frame, columns[2], wizard);
}

fn render_disk_panel(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let state = &wizard.state;
    let items = state
        .disks
        .iter()
        .map(|disk| {
            ListItem::new(Line::from(vec![
                Span::styled(
                    if wizard.state.current_step == InstallStep::Disks
                        && wizard.disk_field == DiskField::Path
                    {
                        format!("[{}]", disk.path)
                    } else {
                        disk.path.clone()
                    },
                    Style::default().fg(Color::White),
                ),
                Span::styled(
                    if wizard.state.current_step == InstallStep::Disks
                        && wizard.disk_field == DiskField::Size
                    {
                        format!("  [{}G]", disk.size_gib)
                    } else {
                        format!("  {}G", disk.size_gib)
                    },
                    Style::default().fg(Color::DarkGray),
                ),
                Span::styled(
                    disk.model
                        .as_deref()
                        .map(|model| format!("  {model}"))
                        .unwrap_or_default(),
                    Style::default().fg(Color::DarkGray),
                ),
            ]))
        })
        .collect::<Vec<_>>();

    let list = List::new(items).block(panel("disks"));
    frame.render_widget(list, area);
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
                .fg(Color::Cyan)
                .bg(Color::Black)
                .add_modifier(Modifier::BOLD),
        )
        .label(label)
        .ratio(state.used_ratio());
    frame.render_widget(gauge, rows[0]);

    let items = state
        .volumes
        .iter()
        .enumerate()
        .map(|(index, volume)| {
            let mount = volume.mountpoint.label();
            let active =
                state.current_step == InstallStep::Volumes && index == wizard.selected_volume;
            ListItem::new(Line::from(vec![
                Span::styled(
                    if active && wizard.volume_field == VolumeField::Name {
                        format!("[{:<4}]", volume.name)
                    } else {
                        format!("{:<6}", volume.name)
                    },
                    Style::default()
                        .fg(Color::White)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    if active && wizard.volume_field == VolumeField::Mountpoint {
                        format!("[{:<6}]", mount)
                    } else {
                        format!("{:<8}", mount)
                    },
                    Style::default().fg(Color::Green),
                ),
                Span::styled(
                    if active && wizard.volume_field == VolumeField::Size {
                        format!("[{:>3}G]", volume.size_gib)
                    } else {
                        format!("{:>4}G", volume.size_gib)
                    },
                    Style::default().fg(Color::Yellow),
                ),
            ]))
        })
        .collect::<Vec<_>>();

    frame.render_widget(List::new(items).block(panel("volumes")), rows[1]);
}

fn render_summary_panel(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let state = &wizard.state;
    let dotfiles = state.dotfiles_repo.as_deref().unwrap_or("none");
    let roles = InstallRole::all()
        .iter()
        .map(|role| role.title())
        .collect::<Vec<_>>()
        .join("/");
    let text = vec![
        Line::from(vec![
            Span::styled("free", Style::default().fg(Color::DarkGray)),
            Span::raw(" "),
            Span::styled(
                format!("{}G", state.free_gib()),
                Style::default()
                    .fg(Color::Green)
                    .add_modifier(Modifier::BOLD),
            ),
        ]),
        Line::raw(""),
        Line::from(Span::styled(
            "dotfiles",
            Style::default().fg(Color::DarkGray),
        )),
        Line::from(Span::styled(dotfiles, Style::default().fg(Color::White))),
        Line::raw(""),
        Line::from(vec![
            Span::styled("roles", Style::default().fg(Color::DarkGray)),
            Span::raw(" "),
            Span::styled(roles, Style::default().fg(Color::White)),
        ]),
        Line::from(vec![
            Span::styled("user", Style::default().fg(Color::DarkGray)),
            Span::raw(" "),
            Span::styled(&state.install_user, Style::default().fg(Color::White)),
        ]),
        Line::from(vec![
            Span::styled("confirm", Style::default().fg(Color::DarkGray)),
            Span::raw(" "),
            Span::styled(
                if wizard.confirm_armed {
                    "armed"
                } else {
                    "locked"
                },
                Style::default().fg(if wizard.confirm_armed {
                    Color::Red
                } else {
                    Color::Green
                }),
            ),
        ]),
        Line::raw(""),
        Line::from(Span::styled(
            &wizard.status,
            Style::default().fg(Color::Yellow),
        )),
    ];
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

fn confirm_summary_lines<'a>(wizard: &'a InstallWizard, mut lines: Vec<Line<'a>>) -> Vec<Line<'a>> {
    let confirmation = wizard.confirmation();
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "destructive confirmation",
        Style::default().fg(Color::DarkGray),
    )));
    lines.push(Line::from(vec![
        Span::styled("target ", Style::default().fg(Color::DarkGray)),
        Span::styled(
            confirmation.target.clone(),
            Style::default().fg(Color::White),
        ),
    ]));
    lines.push(Line::from(vec![
        Span::styled("disks  ", Style::default().fg(Color::DarkGray)),
        Span::styled(confirmation.disk_summary(), Style::default().fg(Color::Red)),
    ]));
    lines.push(Line::from(Span::styled(
        "type exactly:",
        Style::default().fg(Color::DarkGray),
    )));
    lines.push(Line::from(Span::styled(
        confirmation.phrase,
        Style::default().fg(Color::Yellow),
    )));
    lines.push(Line::from(vec![
        Span::styled("input ", Style::default().fg(Color::DarkGray)),
        Span::styled(
            if wizard.confirm_input.is_empty() {
                "<empty>"
            } else {
                &wizard.confirm_input
            },
            Style::default().fg(if wizard.confirm_armed {
                Color::Green
            } else {
                Color::White
            }),
        ),
    ]));
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "preflight",
        Style::default().fg(Color::DarkGray),
    )));
    match &wizard.preflight {
        Some(report) => {
            for check in &report.checks {
                let (marker, color) = match check.status {
                    PreflightStatus::Pass => ("ok", Color::Green),
                    PreflightStatus::Fail => ("fail", Color::Red),
                };
                lines.push(Line::from(vec![
                    Span::styled(format!("{marker:<4}"), Style::default().fg(color)),
                    Span::styled(check.name, Style::default().fg(Color::White)),
                ]));
                lines.push(Line::from(Span::styled(
                    format!("  {}", check.detail),
                    Style::default().fg(Color::DarkGray),
                )));
            }
        }
        None => lines.push(Line::from(Span::styled(
            "press space to run checks",
            Style::default().fg(Color::Yellow),
        ))),
    }
    lines
}

fn render_footer(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let help = Line::from(vec![
        Span::styled("enter", Style::default().fg(Color::Cyan)),
        Span::raw(" next  "),
        Span::styled("esc", Style::default().fg(Color::Cyan)),
        Span::raw(" back  "),
        Span::styled("left/right", Style::default().fg(Color::Cyan)),
        Span::raw(" change  "),
        Span::styled("+/-", Style::default().fg(Color::Cyan)),
        Span::raw(" size  "),
        Span::styled("space", Style::default().fg(Color::Cyan)),
        Span::raw(" toggle  "),
        Span::styled("q", Style::default().fg(Color::Cyan)),
        Span::raw(" quit outside text  "),
        Span::styled("ctrl-c", Style::default().fg(Color::Cyan)),
        Span::raw(" quit  "),
        Span::styled(
            format!(
                "step {}/{}",
                wizard.state.current_step_index() + 1,
                InstallState::steps().len()
            ),
            Style::default().fg(Color::DarkGray),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(help)
            .alignment(Alignment::Center)
            .block(Block::default().borders(Borders::TOP)),
        area,
    );
}

fn panel(title: &'static str) -> Block<'static> {
    Block::default()
        .title(title)
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(Color::DarkGray))
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

    use super::render;
    use crate::install_state::InstallState;
    use crate::install_wizard::InstallWizard;

    #[test]
    fn renders_install_preview_without_panic() {
        let backend = TestBackend::new(100, 32);
        let mut terminal = Terminal::new(backend).unwrap();
        let wizard = InstallWizard::new(InstallState::sample());

        terminal.draw(|frame| render(frame, &wizard)).unwrap();
    }
}
