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
use ratatui::widgets::{Block, BorderType, Borders, Clear, Gauge, List, ListItem, Paragraph, Wrap};
use ratatui::{Frame, Terminal};

use crate::install::preflight::PreflightStatus;
use crate::install::state::{DiskRole, InstallRole, InstallState, InstallStep};
use crate::install::storage::StorageLayout;
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
                terminal.leave()?;
                if execute {
                    return crate::install::exec::run_confirmed(repo, &wizard.state);
                }
                crate::install::exec::prepare_generated(repo, &wizard.state)?;
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

    // Local targets get full facts-based introspection (instant, and it carries
    // partition/LVM contents for the picker); remote targets use the light
    // lsblk-over-ssh probe since the agent is not bootstrapped yet at this step.
    if wizard.state.scope == crate::install::state::InstallScope::Local {
        let facts = crate::facts::collect();
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
        return;
    }

    match crate::install::disk::discover(wizard.state.scope, &wizard.state.remote) {
        Ok(disks) => {
            let count = disks.len();
            let discovered = crate::install::disk::choices_from_disks(&disks);
            wizard.state.discovered_disks = discovered;
            sync_selected_disks_after_discovery(&mut wizard.state);
            wizard.selected_disk = wizard
                .selected_disk
                .min(wizard.state.discovered_disks.len().saturating_sub(1));
            wizard.status = format!(
                "discovered {count} disk(s), selected {} install disk(s)",
                wizard.state.disks.len()
            );
        }
        Err(err) => {
            wizard.status = format!("disk discovery failed; edit manually: {err}");
        }
    }
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
        "ssh",
        if state.allow_ssh { "on" } else { "off" },
        if state.allow_ssh {
            Color::Green
        } else {
            Color::DarkGray
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
            Span::styled("enter", Style::default().fg(Color::Cyan)),
            Span::raw(" continue  "),
            Span::styled("esc", Style::default().fg(Color::Cyan)),
            Span::raw(" back  "),
            Span::styled(&wizard.status, Style::default().fg(Color::Yellow)),
        ]))
        .alignment(Alignment::Center),
        rows[2],
    );
}

fn storage_plan_target_lines(state: &InstallState) -> Vec<Line<'static>> {
    vec![
        Line::from(vec![
            Span::styled("target ", Style::default().fg(Color::DarkGray)),
            Span::styled(state.scope.title(), Style::default().fg(Color::Cyan)),
            Span::raw(" "),
            Span::styled(
                match state.scope {
                    crate::install::state::InstallScope::Remote => state.remote.clone(),
                    crate::install::state::InstallScope::Local => state.mountpoint.clone(),
                },
                Style::default().fg(Color::White),
            ),
            Span::raw("  "),
            Span::styled("host ", Style::default().fg(Color::DarkGray)),
            Span::styled(state.hostname.clone(), Style::default().fg(Color::Green)),
            Span::raw("  "),
            Span::styled("user ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                state.install_user.clone(),
                Style::default().fg(Color::White),
            ),
        ]),
        Line::from(vec![
            Span::styled("mode ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                state.storage_mode.title(),
                Style::default().fg(Color::White),
            ),
            Span::raw("  "),
            Span::styled("overwrite ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                if state.overwrite_existing_storage {
                    "enabled"
                } else {
                    "disabled"
                },
                Style::default().fg(if state.overwrite_existing_storage {
                    Color::Red
                } else {
                    Color::DarkGray
                }),
            ),
            Span::raw("  "),
            Span::styled("source ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                "generated/storage-plan.json",
                Style::default().fg(Color::Blue),
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
            Color::Red
        } else if free < 16 {
            Color::Yellow
        } else {
            Color::Green
        };
        lines.push(Line::from(vec![
            Span::styled(
                group.name.clone(),
                Style::default()
                    .fg(Color::White)
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
            Span::styled("  disks ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                if disks.is_empty() {
                    "-".to_string()
                } else {
                    disks.join(", ")
                },
                Style::default().fg(Color::Blue),
            ),
        ]));

        let volumes = state
            .volumes
            .iter()
            .filter(|volume| state.volume_group_for_volume(&volume.name) == group.name)
            .map(|volume| volume.name.clone())
            .collect::<Vec<_>>();
        lines.push(Line::from(vec![
            Span::styled("  lvs   ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                if volumes.is_empty() {
                    "-".to_string()
                } else {
                    volumes.join(", ")
                },
                Style::default().fg(Color::Green),
            ),
        ]));
        lines.push(Line::raw(""));
    }

    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "no pools",
            Style::default().fg(Color::Red),
        )));
    }
    lines
}

fn storage_plan_disk_and_volume_lines(state: &InstallState) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(Span::styled(
        "disks",
        Style::default().fg(Color::DarkGray),
    ))];

    for disk in state.visible_disks() {
        let role = state.disk_role_for_path(&disk.path);
        let pool = state.disk_volume_group_for_path(&disk.path).unwrap_or("-");
        lines.push(Line::from(vec![
            Span::styled(role.marker(), Style::default().fg(disk_role_color(role))),
            Span::raw(" "),
            Span::styled(disk.path.clone(), Style::default().fg(Color::White)),
            Span::styled(
                format!(" {}G", disk.size_gib),
                Style::default().fg(Color::Yellow),
            ),
            Span::styled(format!(" {pool}"), Style::default().fg(Color::Blue)),
        ]));
    }

    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "logical volumes",
        Style::default().fg(Color::DarkGray),
    )));
    for volume in &state.volumes {
        lines.push(Line::from(vec![
            Span::styled(
                format!("{:<5}", volume.name),
                Style::default()
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("{:<8}", volume.mountpoint.label()),
                Style::default().fg(Color::Green),
            ),
            Span::styled(
                state.volume_group_for_volume(&volume.name).to_string(),
                Style::default().fg(Color::Blue),
            ),
            Span::styled(
                format!(" {}G", volume.size_gib),
                Style::default().fg(Color::Yellow),
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
                        Color::Red,
                    ));
                }
            }
            Err(err) => {
                lines.push(Line::from(Span::styled(
                    format!("preview unavailable: {err}"),
                    Style::default().fg(Color::Red),
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
                Style::default().fg(Color::Red),
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
                Color::Red
            } else {
                Color::DarkGray
            },
        ));
    }
    if actions.len() > limit {
        lines.push(Line::from(Span::styled(
            format!("... {} more", actions.len() - limit),
            Style::default().fg(Color::DarkGray),
        )));
    }
    lines
}

fn render_disk_panel(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let state = &wizard.state;
    let visible_disks = state.visible_disks();
    let items = visible_disks
        .iter()
        .enumerate()
        .map(|(index, disk)| {
            let role = state.disk_role_for_path(&disk.path);
            let pool = state.disk_volume_group_for_path(&disk.path).unwrap_or("-");
            let active = state.current_step == InstallStep::Disks && index == wizard.selected_disk;
            let cursor = if active { ">" } else { " " };
            ListItem::new(Line::from(vec![
                Span::styled(cursor, Style::default().fg(Color::Cyan)),
                Span::raw(" "),
                Span::styled(
                    if active && wizard.disk_field == DiskField::Role {
                        format!("[{}]", role.marker())
                    } else {
                        role.marker().to_string()
                    },
                    Style::default().fg(disk_role_color(role)),
                ),
                Span::styled(
                    format!(" {:<7}", role.title()),
                    Style::default().fg(if active && wizard.disk_field == DiskField::Role {
                        Color::White
                    } else {
                        disk_role_color(role)
                    }),
                ),
                Span::raw(" "),
                Span::styled(
                    if active && wizard.disk_field == DiskField::Pool {
                        format!("[{pool}]")
                    } else {
                        format!("{pool}")
                    },
                    Style::default().fg(if active && wizard.disk_field == DiskField::Pool {
                        Color::Cyan
                    } else {
                        Color::Blue
                    }),
                ),
                Span::raw(" "),
                Span::styled(
                    if active && wizard.disk_field == DiskField::Path {
                        format!("[{}]", disk.path)
                    } else {
                        disk.path.clone()
                    },
                    Style::default().fg(Color::White),
                ),
                Span::styled(
                    if active && wizard.disk_field == DiskField::Size {
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

    let title =
        if state.current_step == InstallStep::Disks && wizard.disk_field == DiskField::Overwrite {
            if state.overwrite_existing_storage {
                "disks overwrite:on"
            } else {
                "disks overwrite:off"
            }
        } else if state.current_step == InstallStep::Disks && wizard.disk_field == DiskField::Pool {
            "disks pool"
        } else if state.current_step == InstallStep::Disks && wizard.disk_field == DiskField::Mode {
            "disks mode"
        } else {
            "disks [S]=system [P]=pool [D]=data [R]=reserve"
        };
    let list = List::new(items).block(panel(title));
    frame.render_widget(list, area);
}

fn disk_role_color(role: DiskRole) -> Color {
    match role {
        DiskRole::System | DiskRole::PoolMember => Color::Green,
        DiskRole::Data => Color::Yellow,
        DiskRole::Reserve => Color::Blue,
        DiskRole::Ignore => Color::DarkGray,
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
            let pool = state.volume_group_for_volume(&volume.name);
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
                    if active && wizard.volume_field == VolumeField::Pool {
                        format!("[{:<6}]", pool)
                    } else {
                        format!("{:<8}", pool)
                    },
                    Style::default().fg(if active && wizard.volume_field == VolumeField::Pool {
                        Color::Cyan
                    } else {
                        Color::Blue
                    }),
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

fn render_pool_panel(frame: &mut Frame<'_>, area: Rect, wizard: &InstallWizard) {
    let state = &wizard.state;
    let (total_by_pool, used_by_pool) = pool_capacity_maps(state);
    let items = state
        .volume_groups
        .iter()
        .enumerate()
        .map(|(index, group)| {
            let active = index == wizard.selected_pool;
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
                Color::Red
            } else if free < 16 {
                Color::Yellow
            } else {
                Color::Green
            };
            ListItem::new(Line::from(vec![
                Span::styled(
                    if active { "> " } else { "  " },
                    Style::default().fg(Color::Cyan),
                ),
                Span::styled(
                    if active {
                        format!("[{}]", group.name)
                    } else {
                        group.name.clone()
                    },
                    Style::default()
                        .fg(if active { Color::Cyan } else { Color::White })
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!(" {used}G/{total}G"),
                    Style::default()
                        .fg(capacity_color)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!(" free {free}G"),
                    Style::default().fg(Color::DarkGray),
                ),
                Span::styled(
                    format!(" disks:{}", if disks.is_empty() { "-" } else { &disks }),
                    Style::default().fg(Color::Blue),
                ),
                Span::styled(
                    format!(" vols:{}", if volumes.is_empty() { "-" } else { &volumes }),
                    Style::default().fg(Color::Green),
                ),
            ]))
        })
        .collect::<Vec<_>>();

    frame.render_widget(List::new(items).block(panel("pools")), area);
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
            Span::styled("storage", Style::default().fg(Color::DarkGray)),
            Span::raw(" "),
            Span::styled(
                state.storage_mode.title(),
                Style::default().fg(
                    if state.current_step == InstallStep::Disks
                        && wizard.disk_field == DiskField::Mode
                    {
                        Color::Cyan
                    } else {
                        Color::White
                    },
                ),
            ),
        ]),
        Line::from(vec![
            Span::styled("filesystem", Style::default().fg(Color::DarkGray)),
            Span::raw(" "),
            Span::styled(
                state.filesystem.title(),
                Style::default().fg(
                    if state.current_step == InstallStep::Disks
                        && wizard.disk_field == DiskField::Filesystem
                    {
                        Color::Cyan
                    } else {
                        Color::White
                    },
                ),
            ),
        ]),
        Line::from(vec![
            Span::styled("encrypt", Style::default().fg(Color::DarkGray)),
            Span::raw(" "),
            Span::styled(
                if state.encrypt { "luks" } else { "off" },
                Style::default().fg(
                    if state.current_step == InstallStep::Disks
                        && wizard.disk_field == DiskField::Encrypt
                    {
                        Color::Cyan
                    } else if state.encrypt {
                        Color::Yellow
                    } else {
                        Color::DarkGray
                    },
                ),
            ),
        ]),
        Line::from(vec![
            Span::styled("ssh", Style::default().fg(Color::DarkGray)),
            Span::raw(" "),
            Span::styled(
                if state.allow_ssh {
                    "enabled"
                } else {
                    "disabled"
                },
                Style::default().fg(if state.allow_ssh {
                    Color::Green
                } else {
                    Color::DarkGray
                }),
            ),
        ]),
        Line::from(vec![
            Span::styled("overwrite", Style::default().fg(Color::DarkGray)),
            Span::raw(" "),
            Span::styled(
                if state.overwrite_existing_storage {
                    "enabled"
                } else {
                    "disabled"
                },
                Style::default().fg(if state.overwrite_existing_storage {
                    Color::Red
                } else {
                    Color::DarkGray
                }),
            ),
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
        Line::from(Span::styled("pools", Style::default().fg(Color::DarkGray))),
    ];
    text.extend(pool_summary_lines(state));
    text.extend(storage_action_preview_lines(state, 8));
    text.extend([
        Line::raw(""),
        Line::from(Span::styled(
            &wizard.status,
            Style::default().fg(Color::Yellow),
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
                Color::Red
            } else if free < 16 {
                Color::Yellow
            } else {
                Color::Green
            };
            Line::from(vec![
                Span::styled(
                    format!("{:<8}", group.name),
                    Style::default().fg(Color::White),
                ),
                Span::styled(
                    format!("{used}G/{total}G"),
                    Style::default().fg(color).add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!(" free {free}G"),
                    Style::default().fg(Color::DarkGray),
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
            Style::default().fg(Color::DarkGray),
        )),
    ];

    if state.overwrite_existing_storage {
        match StorageLayout::from_state(state) {
            Ok(layout) => {
                for vg_name in layout.lvm_vg_names() {
                    lines.push(action_line("remove existing VG", &vg_name, Color::Red));
                }
            }
            Err(err) => {
                lines.push(Line::from(Span::styled(
                    format!("preview unavailable: {err}"),
                    Style::default().fg(Color::Red),
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
                Style::default().fg(Color::Red),
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
                Color::Red
            } else {
                Color::DarkGray
            },
        ));
    }
    if actions.len() > limit {
        lines.push(Line::from(Span::styled(
            format!("... {} more", actions.len() - limit),
            Style::default().fg(Color::DarkGray),
        )));
    }
    lines
}

fn action_line(prefix: &str, text: &str, color: Color) -> Line<'static> {
    Line::from(vec![
        Span::styled(format!("{prefix:<3}"), Style::default().fg(color)),
        Span::styled(text.to_string(), Style::default().fg(Color::White)),
    ])
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
    lines.extend(storage_action_preview_lines(&wizard.state, 24));
    lines.push(Line::raw(""));
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
}
