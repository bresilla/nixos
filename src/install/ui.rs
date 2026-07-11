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
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Margin, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span, Text};
use ratatui::widgets::{Block, Borders, Clear, Gauge, Paragraph, Row, Table, TableState, Wrap};
use ratatui::{Frame, Terminal};
use tui_globe::{project_point, Camera, Globe, MapData};
use tui_popup::Popup;

use crate::install::flow::{Flow, Step, StepKind};
use crate::install::preflight::PreflightStatus;
use crate::install::state::InstallState;
use crate::install::theme;
use crate::Result;

pub fn run(repo: &Path, execute: bool) -> Result<u8> {
    let mut flow = Flow::new(InstallState::draft());
    let mut terminal = PreviewTerminal::enter()?;

    loop {
        flow.poll_link();
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

    // Multi-select disk picker: space toggles, ↑↓ navigate.
    if kind == StepKind::DiskSelect {
        let disks = flow.installable_disks();
        let last = disks.len().saturating_sub(1);
        match key.code {
            KeyCode::Esc => flow.back(),
            KeyCode::Enter => flow.advance(),
            KeyCode::Up | KeyCode::Char('k') => flow.cursor = flow.cursor.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => flow.cursor = (flow.cursor + 1).min(last),
            KeyCode::Char(' ') => {
                if let Some(disk) = disks.get(flow.cursor) {
                    let path = disk.path.clone();
                    flow.disk_toggle(&path);
                }
            }
            KeyCode::Char('q') => flow.quit = true,
            _ => {}
        }
        return;
    }

    // Extra-disks: set a mount for each remaining disk, or skip.
    if kind == StepKind::ExtraDisks {
        if flow.extra_edit.is_some() {
            match key.code {
                KeyCode::Enter => flow.extra_apply_edit(),
                KeyCode::Esc => flow.extra_cancel_edit(),
                KeyCode::Backspace => flow.extra_edit_backspace(),
                KeyCode::Char(ch) => flow.extra_edit_insert(ch),
                _ => {}
            }
            return;
        }
        match key.code {
            KeyCode::Esc => flow.back(),
            KeyCode::Enter => flow.advance(),
            KeyCode::Up | KeyCode::Char('k') => flow.extra_sel_prev(),
            KeyCode::Down | KeyCode::Char('j') => flow.extra_sel_next(),
            KeyCode::Char('m') => flow.extra_begin_edit(),
            KeyCode::Char('s') | KeyCode::Char('d') => flow.extra_clear(),
            KeyCode::Char('q') => flow.quit = true,
            _ => {}
        }
        return;
    }

    // The disk stage is a two-panel pools|volumes editor with direct resizing.
    if let StepKind::Editor(crate::install::flow::Editor::Disks) = kind {
        // Rename mode captures typing until Enter/Esc.
        if flow.disk_rename.is_some() {
            match key.code {
                KeyCode::Enter => flow.disk_apply_rename(),
                KeyCode::Esc => flow.disk_cancel_rename(),
                KeyCode::Backspace => flow.disk_rename_backspace(),
                KeyCode::Char(ch) => flow.disk_rename_insert(ch),
                _ => {}
            }
            return;
        }
        match key.code {
            KeyCode::Esc => flow.back(),
            KeyCode::Enter => flow.advance(),
            KeyCode::Up | KeyCode::Char('k') => flow.disk_sel_prev(),
            KeyCode::Down | KeyCode::Char('j') => flow.disk_sel_next(),
            KeyCode::Left | KeyCode::Char('h') | KeyCode::BackTab => flow.disk_focus_pools(),
            KeyCode::Right | KeyCode::Char('l') | KeyCode::Tab => flow.disk_focus_volumes(),
            KeyCode::Char('+') | KeyCode::Char('=') => flow.disk_resize(8),
            KeyCode::Char('-') | KeyCode::Char('_') => flow.disk_resize(-8),
            KeyCode::PageUp => flow.disk_resize(64),
            KeyCode::PageDown => flow.disk_resize(-64),
            KeyCode::Char('a') => flow.disk_add(),
            KeyCode::Char('d') | KeyCode::Char('x') => flow.disk_delete(),
            KeyCode::Char('r') => flow.disk_begin_rename(),
            KeyCode::Char('m') => flow.enable_manual_storage(),
            KeyCode::Char('q') => flow.quit = true,
            _ => {}
        }
        return;
    }

    // The remaining advanced editors (manual mode) use the generic editor.
    if let StepKind::Editor(editor) = kind {
        let text_field = editor.is_text(flow.field);
        match key.code {
            KeyCode::Esc => flow.back(),
            KeyCode::Enter => flow.advance(),
            KeyCode::Up => flow.item_prev(),
            KeyCode::Down => flow.item_next(),
            KeyCode::Left | KeyCode::BackTab => flow.field_prev(),
            KeyCode::Right | KeyCode::Tab => flow.field_next(),
            KeyCode::Char('n') if key.modifiers.contains(KeyModifiers::CONTROL) => flow.add_item(),
            KeyCode::Char('x') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                flow.remove_item()
            }
            KeyCode::Char(' ') => flow.cycle(),
            KeyCode::Char('+') | KeyCode::Char('=') => flow.adjust(1),
            KeyCode::Char('-') => flow.adjust(-1),
            KeyCode::Char('S') if editor == crate::install::flow::Editor::Volumes => {
                flow.scale_to_fit()
            }
            KeyCode::Backspace if text_field => flow.backspace(),
            KeyCode::Char(ch) if text_field => flow.insert(ch),
            KeyCode::Char('k') => flow.item_prev(),
            KeyCode::Char('j') => flow.item_next(),
            KeyCode::Char('h') => flow.field_prev(),
            KeyCode::Char('l') => flow.field_next(),
            KeyCode::Char('q') => flow.quit = true,
            _ => {}
        }
        return;
    }

    let input_step = matches!(
        kind,
        StepKind::Text | StepKind::Password | StepKind::Confirm
    );
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
        KeyCode::Left if kind == StepKind::Text => flow.text_cursor_prev(),
        KeyCode::Right if kind == StepKind::Text => flow.text_cursor_next(),
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
    let (link_icon, link_word, link_color) = flow.link_badge();
    let (n, total) = flow.step_number();
    let outer = theme::panel_bare()
        .title(Line::from(vec![
            Span::styled(" ⬢ ", Style::default().fg(theme::ACCENT)),
            Span::styled("nox ", theme::title()),
            Span::styled("installer ", theme::dim()),
        ]))
        .title(
            Line::from(vec![
                Span::styled(
                    format!(" {link_icon} {scope} {target} · "),
                    Style::default().fg(link_color),
                ),
                Span::styled(link_word, theme::dim()),
                Span::styled(format!(" · step {n}/{total} "), theme::dim()),
            ])
            .right_aligned(),
        );
    frame.render_widget(outer, shell);

    let inner = shell.inner(Margin {
        horizontal: 2,
        vertical: 1,
    });
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1), // breadcrumb
            Constraint::Min(6),    // full-bleed stage
            Constraint::Length(2), // shortcut chips
        ])
        .split(inner);

    render_breadcrumb(frame, rows[0], flow);
    render_stage(frame, rows[1], flow);
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

    frame.render_widget(
        Paragraph::new(Line::from(spans)).alignment(Alignment::Center),
        area,
    );
}

const STAGE_HEADER_H: u16 = 3; // title + help + spacer

/// Render the one full-bleed stage inside the outer installer shell.  This is
/// deliberately not a `Block`: the shell is the installer’s only frame.
fn render_stage(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let step = flow.current();
    let stage = area.inner(Margin {
        horizontal: 2,
        vertical: 1,
    });
    let header = vec![
        Line::from(Span::styled(step.question(), theme::title())),
        Line::from(Span::styled(step.help(), theme::dim())),
        Line::from(""),
    ];
    let body = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(STAGE_HEADER_H), Constraint::Min(1)])
        .split(stage);
    frame.render_widget(Paragraph::new(header).wrap(Wrap { trim: true }), body[0]);

    match step.kind() {
        StepKind::Choice if step == Step::Locale => render_locale(frame, body[1], flow),
        StepKind::Choice => render_options(frame, body[1], flow),
        StepKind::Text | StepKind::Password => render_input(frame, body[1], flow),
        StepKind::DiskSelect => render_disk_select(frame, body[1], flow),
        StepKind::ExtraDisks => render_extra_disks(frame, body[1], flow),
        StepKind::Editor(crate::install::flow::Editor::Disks) => {
            render_disk_stage(frame, body[1], flow)
        }
        StepKind::Editor(editor) => render_editor(frame, body[1], flow, editor),
        StepKind::Review => render_review(frame, body[1], flow),
        StepKind::Confirm => render_confirm(frame, body[1], flow),
    }
}

/// Multi-select disk picker with checkboxes + partition bars.
fn render_disk_select(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let disks = flow.installable_disks();
    if disks.is_empty() {
        let msg = flow
            .disk_error
            .clone()
            .map(|e| format!("discovery failed: {e}"))
            .unwrap_or_else(|| "no installable disks (boot media excluded)".to_string());
        frame.render_widget(
            Paragraph::new(Span::styled(msg, Style::default().fg(theme::RED))).wrap(Wrap { trim: true }),
            area,
        );
        return;
    }
    let mut rows: Vec<Row> = Vec::new();
    for (i, disk) in disks.iter().enumerate() {
        let on = flow.is_disk_selected(&disk.path);
        let selected = i == flow.cursor;
        let check = if on {
            Span::styled("[✓] ", Style::default().fg(theme::GREEN))
        } else {
            Span::styled("[ ] ", theme::dim())
        };
        let name = Span::styled(
            disk.path.clone(),
            if selected {
                theme::text().add_modifier(Modifier::BOLD)
            } else {
                theme::subtle()
            },
        );
        let desc = format!(
            "{}G · {} · {}",
            disk.size_gib,
            disk.model.as_deref().unwrap_or("disk"),
            flow.disk_contents(&disk.path),
        );
        rows.push(
            Row::new(vec![theme::cell2(
                Line::from(vec![check, name]),
                Span::styled(desc, theme::dim()),
            )])
            .height(2),
        );
    }
    let table = Table::new(rows, [Constraint::Percentage(100)])
        .row_highlight_style(theme::selected_row())
        .highlight_symbol(Text::from(vec![
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
        ]));
    let mut ts = TableState::default();
    ts.select(Some(flow.cursor.min(disks.len().saturating_sub(1))));
    frame.render_stateful_widget(table, area, &mut ts);
}

/// Per-disk mount config for disks not used by the install.
fn render_extra_disks(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let disks = flow.extra_disks();
    if disks.is_empty() {
        frame.render_widget(
            Paragraph::new(Span::styled("No other disks — press Enter to continue.", theme::dim())),
            area,
        );
        return;
    }
    let mut rows: Vec<Row> = Vec::new();
    for (i, disk) in disks.iter().enumerate() {
        let selected = i == flow.extra_sel;
        let mount = if selected && flow.extra_edit.is_some() {
            Span::styled(
                format!("[{}█]", flow.extra_edit.as_deref().unwrap_or("")),
                Style::default().fg(theme::ACCENT).add_modifier(Modifier::BOLD),
            )
        } else {
            match flow.extra_mount_of(&disk.path) {
                Some(m) => Span::styled(format!("→ {m}"), Style::default().fg(theme::GREEN)),
                None => Span::styled("skip", theme::dim()),
            }
        };
        let name = Span::styled(
            disk.path.clone(),
            if selected {
                theme::text().add_modifier(Modifier::BOLD)
            } else {
                theme::subtle()
            },
        );
        rows.push(
            Row::new(vec![theme::cell2(
                Line::from(vec![name, Span::raw("  "), mount]),
                Span::styled(
                    format!(
                        "{}G · {} · {}",
                        disk.size_gib,
                        disk.model.as_deref().unwrap_or("disk"),
                        flow.disk_contents(&disk.path)
                    ),
                    theme::dim(),
                ),
            )])
            .height(2),
        );
    }
    let table = Table::new(rows, [Constraint::Percentage(100)])
        .row_highlight_style(theme::selected_row())
        .highlight_symbol(Text::from(vec![
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
        ]));
    let mut ts = TableState::default();
    ts.select(Some(flow.extra_sel.min(disks.len().saturating_sub(1))));
    frame.render_stateful_widget(table, area, &mut ts);
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
                    Style::default()
                        .fg(theme::TEXT)
                        .add_modifier(Modifier::BOLD),
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

/// The locale step: a timezone list on the left, a globe on the right rotated
/// to the highlighted location with a pin. Ubuntu-installer "where are you?".
fn render_locale(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(48), Constraint::Percentage(52)])
        .split(area);

    render_options(frame, cols[0], flow);

    let map_area = cols[1];
    if map_area.width < 20 || map_area.height < 8 {
        return;
    }
    let (lat, lon) = flow.locale_coords();
    render_globe(frame, map_area, lat, lon, &flow.state.timezone);
}

/// A braille globe (d10n/tui-globe) rotated so the selected location faces the
/// camera, with a pin dropped on it and the timezone captioned below.
fn render_globe(frame: &mut Frame<'_>, area: Rect, lat: f32, lon: f32, tz: &str) {
    // Leave the bottom row for the caption.
    let globe_area = Rect {
        height: area.height.saturating_sub(1),
        ..area
    };
    let camera = Camera {
        yaw: -lon.to_radians(),
        pitch: lat.to_radians(),
        zoom: 1.4,
    };
    let map = MapData::embedded();
    frame.render_widget(Globe::new(&map, camera), globe_area);

    if let Some((px, py)) = project_point(lat, lon, camera, globe_area) {
        if let Some(cell) = frame.buffer_mut().cell_mut((px, py)) {
            cell.set_symbol("◉");
            cell.set_style(Style::default().fg(theme::RED).add_modifier(Modifier::BOLD));
        }
    }

    let caption = Rect {
        x: area.x,
        y: area.y + area.height.saturating_sub(1),
        width: area.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("◉ ", Style::default().fg(theme::RED)),
            Span::styled(tz.to_string(), Style::default().fg(theme::TEXT)),
        ]))
        .alignment(Alignment::Center),
        caption,
    );
}

fn disk_role_color(role: crate::install::state::DiskRole) -> ratatui::style::Color {
    use crate::install::state::DiskRole;
    match role {
        DiskRole::System | DiskRole::PoolMember => theme::GREEN,
        DiskRole::Data => theme::YELLOW,
        DiskRole::Reserve => theme::BLUE,
        DiskRole::Ignore => theme::MUTED,
    }
}

/// The disk stage is intentionally a visual overview first and the existing
/// powerful editor second.  A person can see what is on a drive before they
/// give it a destructive role, without another framed "card" around it.
fn render_disk_stage(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let disk_count = flow.facts.as_ref().map(|f| f.disks.len()).unwrap_or(0) as u16;
    let bars_h = (disk_count * 2 + 1).clamp(1, area.height / 3);
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(bars_h),  // detected disks
            Constraint::Length(6),       // capacity bar for the selected pool
            Constraint::Min(4),          // pools | volumes panels
        ])
        .split(area);

    // Detected disks as partition bars.
    if let Some(facts) = &flow.facts {
        render_partition_bars(frame, rows[0], facts, None);
    } else if let Some(err) = &flow.disk_error {
        frame.render_widget(
            Paragraph::new(Span::styled(
                format!("✗ disk discovery: {err}"),
                Style::default().fg(theme::RED),
            )),
            rows[0],
        );
    } else {
        frame.render_widget(
            Paragraph::new(Span::styled("○ discovering target disks…", theme::dim())),
            rows[0],
        );
    }

    render_capacity_bar(frame, rows[1], flow);

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(38), Constraint::Percentage(62)])
        .split(rows[2]);
    render_pools_panel(frame, cols[0], flow);
    render_volumes_panel(frame, cols[1], flow);
}

fn panel_title(text: &str, focused: bool) -> Line<'static> {
    if focused {
        Line::from(Span::styled(
            format!("▸ {} ", text.to_uppercase()),
            Style::default().fg(theme::ACCENT).add_modifier(Modifier::BOLD),
        ))
    } else {
        Line::from(Span::styled(format!("  {} ", text.to_uppercase()), theme::dim()))
    }
}

fn render_pools_panel(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    use crate::install::flow::DiskPane;
    let focused = flow.disk_pane == DiskPane::Pools;
    let mut lines = vec![panel_title("pools", focused), Line::from("")];
    for (i, pool) in flow.state.volume_groups.iter().enumerate() {
        let cap = flow.pool_capacity_gib(&pool.name);
        let used = flow.pool_used_gib(&pool.name);
        let selected = i == flow.pool_sel;
        let bar = Span::styled(
            if selected && focused { "▌ " } else { "  " },
            Style::default().fg(theme::ACCENT),
        );
        let name_span = if selected && focused && flow.disk_rename.is_some() {
            Span::styled(
                format!("[{}█]", flow.disk_rename.as_deref().unwrap_or("")),
                Style::default().fg(theme::ACCENT).add_modifier(Modifier::BOLD),
            )
        } else {
            Span::styled(
                pool.name.clone(),
                if selected {
                    theme::text().add_modifier(Modifier::BOLD)
                } else {
                    theme::subtle()
                },
            )
        };
        lines.push(Line::from(vec![bar, name_span]));
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(format!("{used}G / {cap}G"), theme::dim()),
        ]));
    }
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: true }), area);
}

fn render_volumes_panel(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    use crate::install::flow::DiskPane;
    let focused = flow.disk_pane == DiskPane::Volumes;
    let pool = flow.selected_pool_name().unwrap_or_default();
    let members = flow.volumes_in_selected_pool();

    let mut lines = vec![panel_title(&format!("volumes · {pool}"), focused), Line::from("")];
    if members.is_empty() {
        lines.push(Line::from(Span::styled("  (empty — press a to add)", theme::dim())));
    }
    for (row, &vi) in members.iter().enumerate() {
        let vol = &flow.state.volumes[vi];
        let selected = row == flow.vol_sel && focused;
        let bar = Span::styled(
            if selected { "▌ " } else { "  " },
            Style::default().fg(theme::ACCENT),
        );
        let name_span = if selected && flow.disk_rename.is_some() {
            Span::styled(
                format!("[{}█]", flow.disk_rename.as_deref().unwrap_or("")),
                Style::default().fg(theme::ACCENT).add_modifier(Modifier::BOLD),
            )
        } else {
            Span::styled(
                format!("{:<10}", vol.name),
                if selected {
                    theme::text().add_modifier(Modifier::BOLD)
                } else {
                    theme::subtle()
                },
            )
        };
        lines.push(Line::from(vec![
            bar,
            name_span,
            Span::styled(format!("{:<10}", vol.mountpoint.label()), theme::dim()),
            Span::styled(
                format!("{}G", vol.size_gib),
                Style::default()
                    .fg(theme::YELLOW)
                    .add_modifier(if selected { Modifier::BOLD } else { Modifier::empty() }),
            ),
            if selected {
                Span::styled("  −/+ resize", Style::default().fg(theme::ACCENT))
            } else {
                Span::raw("")
            },
        ]));
    }
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: true }), area);
}

fn render_partition_bars(
    frame: &mut Frame<'_>,
    area: Rect,
    facts: &crate::facts::TargetFacts,
    selected_path: Option<&str>,
) {
    let mut lines = Vec::new();
    for disk in facts.disks.iter().take(area.height as usize / 2) {
        let selected = Some(disk.path.as_str()) == selected_path;
        let marker = if selected { "▌" } else { " " };
        let in_use = disk
            .partitions
            .iter()
            .any(|partition| !partition.mountpoints.is_empty());
        lines.push(Line::from(vec![
            Span::styled(marker, Style::default().fg(theme::ACCENT)),
            Span::styled(
                format!(
                    " {}  {}  {}{}",
                    short_disk(&disk.path),
                    format_bytes(disk.size_bytes),
                    disk.model.as_deref().unwrap_or("disk"),
                    if in_use { "  (in use)" } else { "" },
                ),
                if selected {
                    theme::text().add_modifier(Modifier::BOLD)
                } else {
                    theme::subtle()
                },
            ),
        ]));
        lines.push(partition_bar_line(
            disk,
            area.width.saturating_sub(2) as usize,
        ));
    }
    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "No block disks reported by target",
            theme::dim(),
        )));
    }
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: true }), area);
}

fn partition_bar_line(disk: &crate::facts::DiskFacts, width: usize) -> Line<'static> {
    let width = width.clamp(12, 76);
    let total = disk.size_bytes.max(1);
    let used: u64 = disk.partitions.iter().map(|part| part.size_bytes).sum();
    let mut spans = Vec::new();
    for part in &disk.partitions {
        let cells = ((part.size_bytes.saturating_mul(width as u64) / total) as usize).max(1);
        let label = part
            .fstype
            .as_deref()
            .or(part.label.as_deref())
            .unwrap_or("other");
        spans.extend(bar_segment(label, cells, fstype_color(part.fstype.as_deref())));
        spans.push(Span::raw(" "));
    }
    let free = total.saturating_sub(used);
    if free > 0 || spans.is_empty() {
        let cells = ((free.saturating_mul(width as u64) / total) as usize).max(1);
        spans.extend(bar_segment("free", cells, theme::MUTED));
    }
    Line::from(spans)
}

/// One bar segment: a solid block fill in `color`, with `label` cut out of the
/// middle (dark ink on the colored fill) when it fits. Returned as spans so the
/// label stays readable rather than blending into the fill.
fn bar_segment(label: &str, cells: usize, color: ratatui::style::Color) -> Vec<Span<'static>> {
    let block = Style::default().fg(color);
    if cells <= 1 {
        return vec![Span::styled("▏", block)];
    }
    let label_len = label.chars().count();
    if cells < label_len + 2 {
        return vec![Span::styled("█".repeat(cells), block)];
    }
    let pad = cells - label_len;
    let left = pad / 2;
    let right = pad - left;
    vec![
        Span::styled("█".repeat(left), block),
        Span::styled(
            label.to_string(),
            Style::default()
                .fg(theme::SURFACE_LO)
                .bg(color)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled("█".repeat(right), block),
    ]
}


/// The planned pool layout as a chunky 3-row stacked bar: each volume is a
/// background-colored band with its name written down the middle row, the free
/// tail muted. Mirrors the old bash `render_capacity_graph`, thickened.
fn render_capacity_bar(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    // The bar shows the SELECTED pool's allocation, so resizing a volume is
    // immediately visible against that pool's capacity.
    let pool = flow.selected_pool_name().unwrap_or_default();
    let total = flow.pool_capacity_gib(&pool);
    let members = flow.volumes_in_selected_pool();
    let used: u64 = members.iter().map(|&i| flow.state.volumes[i].size_gib).sum();
    let free = total.saturating_sub(used);
    let over = used > total;

    // segment = (label, cells, color, size_gib)
    let bar_w = (area.width as usize).saturating_sub(2).clamp(20, 160);
    let denom = total.max(1);
    let mut segs: Vec<(String, usize, ratatui::style::Color, u64)> = Vec::new();
    for (order, &i) in members.iter().enumerate() {
        let vol = &flow.state.volumes[i];
        let cells = ((vol.size_gib.saturating_mul(bar_w as u64) / denom) as usize)
            .max(if vol.size_gib > 0 { 1 } else { 0 });
        segs.push((vol.name.clone(), cells, volume_color(order), vol.size_gib));
    }
    if free > 0 || segs.is_empty() {
        let cells = ((free.saturating_mul(bar_w as u64) / denom) as usize).max(1);
        segs.push(("free".to_string(), cells, theme::MUTED, free));
    }

    // Title / stats.
    let mut lines = vec![Line::from(vec![
        Span::styled(format!("pool {pool}  "), theme::subtle()),
        Span::styled(
            format!("{used}G "),
            Style::default()
                .fg(if over { theme::RED } else { theme::TEXT })
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("of {total}G  ·  free {free}G"), theme::dim()),
        if over {
            Span::styled("  ✗ over capacity", Style::default().fg(theme::RED))
        } else {
            Span::raw("")
        },
    ])];

    // 3 bar rows: solid band, band + centered labels, solid band.
    let band = |with_label: bool| -> Line<'static> {
        let mut spans = Vec::new();
        for (label, cells, color, _) in &segs {
            if *cells == 0 {
                continue;
            }
            if with_label && *cells >= label.chars().count() + 2 {
                let pad = cells - label.chars().count();
                let left = pad / 2;
                let right = pad - left;
                spans.push(Span::styled(" ".repeat(left), Style::default().bg(*color)));
                spans.push(Span::styled(
                    label.clone(),
                    Style::default()
                        .fg(theme::SURFACE_LO)
                        .bg(*color)
                        .add_modifier(Modifier::BOLD),
                ));
                spans.push(Span::styled(" ".repeat(right), Style::default().bg(*color)));
            } else {
                spans.push(Span::styled(" ".repeat(*cells), Style::default().bg(*color)));
            }
        }
        Line::from(spans)
    };
    lines.push(band(false));
    lines.push(band(true));
    lines.push(band(false));

    // Legend with sizes.
    let mut legend = Vec::new();
    for (label, _, color, size) in &segs {
        legend.push(Span::styled("● ", Style::default().fg(*color)));
        legend.push(Span::styled(format!("{label} {size}G   "), theme::dim()));
    }
    lines.push(Line::from(legend));

    frame.render_widget(Paragraph::new(lines), area);
}

fn fstype_color(fstype: Option<&str>) -> ratatui::style::Color {
    match fstype.unwrap_or("").to_ascii_lowercase().as_str() {
        "vfat" | "fat" | "fat32" => theme::BLUE,
        "ext4" => theme::GREEN,
        "btrfs" => theme::MAUVE,
        "xfs" => theme::PEACH,
        "swap" => theme::YELLOW,
        "lvm2_member" => theme::SKY,
        "ntfs" | "exfat" => theme::RED,
        _ => theme::MUTED,
    }
}

fn volume_color(index: usize) -> ratatui::style::Color {
    [
        theme::GREEN,
        theme::MAUVE,
        theme::BLUE,
        theme::PEACH,
        theme::YELLOW,
        theme::SKY,
    ][index % 6]
}

fn short_disk(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn format_bytes(bytes: u64) -> String {
    const GIB: u64 = 1024 * 1024 * 1024;
    if bytes >= GIB {
        format!("{:.1}G", bytes as f64 / GIB as f64)
    } else {
        format!("{}M", bytes / (1024 * 1024))
    }
}

/// A field value inside an editor row. The focused field is bracketed and, when
/// it is a text field, shows the live edit buffer with a cursor.
fn field_span(
    flow: &Flow,
    editor: crate::install::flow::Editor,
    item: usize,
    field: usize,
    value: String,
    base: ratatui::style::Color,
) -> Span<'static> {
    let focused = item == flow.item && field == flow.field;
    if focused && editor.is_text(field) {
        Span::styled(
            format!("[{}█]", flow.buffer),
            Style::default()
                .fg(theme::ACCENT)
                .add_modifier(Modifier::BOLD),
        )
    } else if focused {
        Span::styled(
            format!("[{value}]"),
            Style::default()
                .fg(theme::ACCENT)
                .add_modifier(Modifier::BOLD),
        )
    } else {
        Span::styled(value, Style::default().fg(base))
    }
}

fn render_editor(
    frame: &mut Frame<'_>,
    area: Rect,
    flow: &Flow,
    editor: crate::install::flow::Editor,
) {
    use crate::install::flow::Editor;

    if flow.item_count() == 0 {
        let msg = flow
            .disk_error
            .clone()
            .map(|e| format!("discovery failed: {e}"))
            .unwrap_or_else(|| "empty — press ^n to add".to_string());
        frame.render_widget(
            Paragraph::new(Span::styled(msg, theme::dim())).wrap(Wrap { trim: true }),
            area,
        );
        return;
    }

    let state = &flow.state;
    let (rows, widths): (Vec<Row>, Vec<Constraint>) = match editor {
        Editor::Disks => {
            let rows = state
                .disks
                .iter()
                .enumerate()
                .map(|(i, disk)| {
                    let role = state.disk_role_for_path(&disk.path);
                    let pool = state
                        .disk_volume_group_for_path(&disk.path)
                        .unwrap_or("-")
                        .to_string();
                    let rc = disk_role_color(role);
                    Row::new(vec![
                        theme::cell2(
                            field_span(
                                flow,
                                editor,
                                i,
                                0,
                                format!("{} {}", role.marker(), role.title()),
                                rc,
                            ),
                            Line::from(vec![
                                Span::styled("pool ", theme::dim()),
                                field_span(flow, editor, i, 1, pool, theme::BLUE),
                            ]),
                        ),
                        theme::cell2(
                            field_span(flow, editor, i, 2, disk.path.clone(), theme::TEXT),
                            Line::from(vec![
                                field_span(
                                    flow,
                                    editor,
                                    i,
                                    3,
                                    format!("{}G", disk.size_gib),
                                    theme::YELLOW,
                                ),
                                Span::styled(
                                    format!(" · {}", disk.model.as_deref().unwrap_or("disk")),
                                    theme::dim(),
                                ),
                            ]),
                        ),
                    ])
                    .height(2)
                })
                .collect();
            (rows, vec![Constraint::Length(20), Constraint::Min(16)])
        }
        Editor::Volumes => {
            let rows = state
                .volumes
                .iter()
                .enumerate()
                .map(|(i, vol)| {
                    let pool = state.volume_group_for_volume(&vol.name).to_string();
                    Row::new(vec![
                        theme::cell2(
                            field_span(flow, editor, i, 0, vol.name.clone(), theme::TEXT),
                            field_span(
                                flow,
                                editor,
                                i,
                                1,
                                vol.mountpoint.label().to_string(),
                                theme::GREEN,
                            ),
                        ),
                        theme::cell2(
                            field_span(
                                flow,
                                editor,
                                i,
                                3,
                                format!("{}G", vol.size_gib),
                                theme::YELLOW,
                            ),
                            Line::from(vec![
                                Span::styled("on ", theme::dim()),
                                field_span(flow, editor, i, 2, pool, theme::BLUE),
                            ]),
                        ),
                    ])
                    .height(2)
                })
                .collect();
            (rows, vec![Constraint::Min(16), Constraint::Length(14)])
        }
        Editor::Pools => {
            let rows = state
                .volume_groups
                .iter()
                .enumerate()
                .map(|(i, pool)| {
                    let disks = state
                        .disks
                        .iter()
                        .filter(|d| {
                            state.disk_volume_group_for_path(&d.path) == Some(pool.name.as_str())
                        })
                        .map(|d| d.path.rsplit('/').next().unwrap_or(&d.path))
                        .collect::<Vec<_>>()
                        .join("+");
                    let vols = state
                        .volumes
                        .iter()
                        .filter(|v| state.volume_group_for_volume(&v.name) == pool.name)
                        .map(|v| v.name.as_str())
                        .collect::<Vec<_>>()
                        .join(",");
                    Row::new(vec![theme::cell2(
                        field_span(flow, editor, i, 0, pool.name.clone(), theme::TEXT),
                        Line::from(vec![
                            Span::styled("disks ", theme::dim()),
                            Span::styled(
                                if disks.is_empty() { "-".into() } else { disks },
                                Style::default().fg(theme::BLUE),
                            ),
                            Span::styled("  vols ", theme::dim()),
                            Span::styled(
                                if vols.is_empty() { "-".into() } else { vols },
                                Style::default().fg(theme::GREEN),
                            ),
                        ]),
                    )])
                    .height(2)
                })
                .collect();
            (rows, vec![Constraint::Percentage(100)])
        }
        Editor::DocSubvols => {
            let rows = state
                .doc_subvolumes
                .iter()
                .enumerate()
                .map(|(i, sub)| {
                    Row::new(vec![theme::cell2(
                        Line::from(vec![
                            Span::styled("/doc/", theme::dim()),
                            field_span(flow, editor, i, 0, sub.clone(), theme::TEXT),
                        ]),
                        Span::styled("btrfs subvolume", theme::dim()),
                    )])
                    .height(2)
                })
                .collect();
            (rows, vec![Constraint::Percentage(100)])
        }
    };

    let table = Table::new(rows, widths)
        .row_highlight_style(theme::selected_row())
        .highlight_symbol(ratatui::text::Text::from(vec![
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
            Line::from(Span::styled("▌", Style::default().fg(theme::ACCENT))),
        ]));
    let mut ts = TableState::default();
    ts.select(Some(flow.item.min(flow.item_count().saturating_sub(1))));
    frame.render_stateful_widget(table, area, &mut ts);
}

fn render_input(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let step = flow.current();
    let masked = step.kind() == StepKind::Password;
    let raw = if step == Step::PasswordConfirm {
        &flow.password_confirm
    } else if masked {
        &flow.password
    } else {
        &flow.buffer
    };
    let shown = if masked {
        "•".repeat(raw.chars().count())
    } else {
        raw.clone()
    };
    let value_empty = shown.is_empty();
    let cursor = if masked {
        shown.chars().count()
    } else {
        flow.text_cursor().min(shown.chars().count())
    };

    // Underlined input line — the outer shell is the only frame.
    let field = Line::from(vec![
        Span::styled("❯ ", Style::default().fg(theme::ACCENT)),
        if value_empty {
            Span::styled(
                match step {
                    Step::Dotfiles => "(blank to skip)",
                    Step::Password | Step::PasswordConfirm => "(hidden)",
                    _ => "type here…",
                },
                theme::dim(),
            )
        } else {
            Span::styled(
                shown.chars().take(cursor).collect::<String>(),
                Style::default().fg(theme::TEXT).add_modifier(Modifier::BOLD),
            )
        },
        Span::styled("█", Style::default().fg(theme::ACCENT)),
        Span::styled(
            shown.chars().skip(cursor).collect::<String>(),
            Style::default().fg(theme::TEXT).add_modifier(Modifier::BOLD),
        ),
    ]);

    // Status line under the field: password match / strength / hint.
    let status = match step {
        Step::PasswordConfirm => {
            if flow.password_confirm.is_empty() {
                Line::from(Span::styled("re-enter to confirm", theme::dim()))
            } else if flow.password_confirm == flow.password {
                Line::from(Span::styled("✓ passwords match", Style::default().fg(theme::GREEN)))
            } else {
                Line::from(Span::styled("✗ does not match", Style::default().fg(theme::RED)))
            }
        }
        Step::Password => {
            if flow.password.is_empty() {
                Line::from(Span::styled("no password — account will be unlocked", theme::dim()))
            } else {
                Line::from(vec![
                    Span::styled(
                        format!("{} chars  ", flow.password.chars().count()),
                        theme::dim(),
                    ),
                    Span::styled(
                        password_strength(&flow.password),
                        Style::default().fg(theme::YELLOW),
                    ),
                ])
            }
        }
        _ => Line::from(Span::raw("")),
    };

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(2), Constraint::Min(1)])
        .split(area);
    frame.render_widget(
        Paragraph::new(field).block(
            Block::default()
                .borders(Borders::BOTTOM)
                .border_style(Style::default().fg(theme::SURFACE)),
        ),
        rows[0],
    );
    frame.render_widget(Paragraph::new(status), rows[1]);
}

fn password_strength(pw: &str) -> &'static str {
    let len = pw.chars().count();
    let classes = [
        pw.chars().any(|c| c.is_lowercase()),
        pw.chars().any(|c| c.is_uppercase()),
        pw.chars().any(|c| c.is_ascii_digit()),
        pw.chars().any(|c| !c.is_alphanumeric()),
    ]
    .iter()
    .filter(|b| **b)
    .count();
    match (len, classes) {
        (0..=5, _) => "weak",
        (6..=9, 0..=2) => "fair",
        (_, 0..=2) => "good",
        _ => "strong",
    }
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
        kv(
            "scope",
            format!(
                "{} {}",
                state.scope.title(),
                if state.scope == crate::install::state::InstallScope::Remote {
                    state.remote.clone()
                } else {
                    "this machine".into()
                }
            ),
            theme::TEXT,
        ),
        kv("hostname", state.hostname.clone(), theme::TEXT),
        kv("user", state.install_user.clone(), theme::TEXT),
        kv(
            "password",
            if flow.password.is_empty() {
                "none".into()
            } else {
                "set".into()
            },
            if flow.password.is_empty() {
                theme::YELLOW
            } else {
                theme::GREEN
            },
        ),
        kv("role", state.role.title().to_string(), theme::TEXT),
        kv(
            "ssh",
            if state.allow_ssh {
                "enabled".into()
            } else {
                "disabled".into()
            },
            if state.allow_ssh {
                theme::GREEN
            } else {
                theme::MUTED
            },
        ),
        kv("disk", disk, theme::TEXT),
        kv(
            "filesystem",
            state.filesystem.title().to_string(),
            theme::TEXT,
        ),
        kv(
            "encrypt",
            if state.encrypt {
                "yes".into()
            } else {
                "no".into()
            },
            if state.encrypt {
                theme::GREEN
            } else {
                theme::MUTED
            },
        ),
        kv(
            "overwrite",
            if state.overwrite_existing_storage {
                "wipe".into()
            } else {
                "keep".into()
            },
            if state.overwrite_existing_storage {
                theme::RED
            } else {
                theme::MUTED
            },
        ),
        kv(
            "dotfiles",
            state.dotfiles_repo.clone().unwrap_or_else(|| "skip".into()),
            theme::SUBTEXT,
        ),
    ];
    frame.render_widget(Paragraph::new(summary).wrap(Wrap { trim: true }), cols[0]);

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
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: true }), cols[1]);
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
        Line::from(Span::styled(
            phrase,
            Style::default()
                .fg(theme::YELLOW)
                .add_modifier(Modifier::BOLD),
        )),
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
            if armed {
                "✓ armed — enter to install"
            } else {
                "locked"
            },
            Style::default().fg(if armed { theme::GREEN } else { theme::MUTED }),
        )),
    ];
    frame.render_widget(
        Paragraph::new(lines)
            .alignment(Alignment::Center)
            .wrap(Wrap { trim: true }),
        area,
    );
}

fn render_flow_footer(frame: &mut Frame<'_>, area: Rect, flow: &Flow) {
    let mut chips: Vec<Span> = Vec::new();
    match flow.current().kind() {
        StepKind::Choice => {
            chips.extend(theme::chip("↑↓", "choose"));
            chips.extend(theme::chip("↵", "next"));
        }
        StepKind::Text | StepKind::Password => {
            chips.extend(theme::chip("type", "edit"));
            chips.extend(theme::chip("↵", "next"));
        }
        StepKind::DiskSelect => {
            chips.extend(theme::chip("↑↓", "disk"));
            chips.extend(theme::chip("␣", "toggle"));
            chips.extend(theme::chip("↵", "next"));
        }
        StepKind::ExtraDisks => {
            chips.extend(theme::chip("↑↓", "disk"));
            chips.extend(theme::chip("m", "mount"));
            chips.extend(theme::chip("s", "skip"));
            chips.extend(theme::chip("↵", "next"));
        }
        StepKind::Editor(_) if flow.current() == Step::Storage => {
            // The disk-stage pool/volume editor.
            chips.extend(theme::chip("←→", "pool/vols"));
            chips.extend(theme::chip("↑↓", "select"));
            chips.extend(theme::chip("−/+", "resize"));
            chips.extend(theme::chip("a", "add"));
            chips.extend(theme::chip("d", "del"));
            chips.extend(theme::chip("r", "rename"));
            chips.extend(theme::chip("↵", "next"));
        }
        StepKind::Editor(_) => {
            chips.extend(theme::chip("↑↓", "item"));
            chips.extend(theme::chip("←→", "field"));
            chips.extend(theme::chip("␣", "cycle"));
            chips.extend(theme::chip("^n", "add"));
            chips.extend(theme::chip("^x", "del"));
            if flow.current() == Step::Volumes {
                chips.extend(theme::chip("S", "fit"));
            }
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
    chips.extend(theme::chip(
        "esc",
        if flow.pos == 0 { "quit" } else { "back" },
    ));

    // A thin rule and one chip row replace the old permanently-empty status box.
    let status = if flow.current() == Step::Storage {
        let pane = match flow.disk_pane {
            crate::install::flow::DiskPane::Pools => "pools",
            crate::install::flow::DiskPane::Volumes => "volumes",
        };
        Span::styled(format!(" editing: {pane}"), theme::subtle())
    } else if let StepKind::Editor(editor) = flow.current().kind() {
        Span::styled(
            format!(" field: {}", editor.field_name(flow.field)),
            theme::subtle(),
        )
    } else if flow.status.is_empty() {
        Span::raw("")
    } else {
        Span::styled(
            format!(" {}", flow.status),
            Style::default().fg(theme::YELLOW),
        )
    };
    chips.push(status);
    frame.render_widget(
        Paragraph::new(Line::from(chips)).block(
            Block::default()
                .borders(Borders::TOP)
                .border_style(Style::default().fg(theme::SURFACE)),
        ),
        area,
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
                    if matches!(key.code, KeyCode::Char('q') | KeyCode::Esc | KeyCode::Enter) {
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
                if progress.failed {
                    " FAILED "
                } else {
                    " DONE "
                },
                Style::default()
                    .fg(theme::SURFACE_LO)
                    .bg(if progress.failed {
                        theme::RED
                    } else {
                        theme::GREEN
                    })
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
    if progress.finished {
        render_install_result_popup(frame, progress);
    }
}

fn render_install_result_popup(
    frame: &mut Frame<'_>,
    progress: &crate::install::progress::ProgressState,
) {
    let (title, color, headline) = if progress.failed {
        (
            " install failed ",
            theme::RED,
            "✗ installation did not complete",
        )
    } else {
        (
            " install complete ",
            theme::GREEN,
            "✓ installation completed",
        )
    };
    let body = Text::from(vec![
        Line::from(Span::styled(
            headline,
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(Span::styled(
            progress
                .summary
                .clone()
                .unwrap_or_else(|| "No summary was reported.".to_string()),
            theme::text(),
        )),
        Line::from(""),
        Line::from(Span::styled("Press Enter, Esc, or q to exit", theme::dim())),
    ]);
    let popup = Popup::new(body)
        .title(Line::from(Span::styled(
            title,
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        )))
        .style(Style::default().fg(theme::TEXT).bg(theme::SURFACE_LO))
        .border_style(Style::default().fg(color));
    frame.render_widget(&popup, frame.area());
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
        flow.disable_discovery = true;
        // Seed a disk so the picker can commit, then advance to the (now late)
        // password step with sensible defaults at each stop.
        flow.state.discovered_disks = vec![crate::install::state::DiskChoice {
            path: "/dev/sda".into(),
            size_gib: 512,
            model: None,
        }];
        flow.cursor = 0; // local
        for _ in 0..40 {
            if flow.current() == Step::Password {
                break;
            }
            flow.advance();
        }
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

    #[test]
    fn partition_categories_have_stable_distinct_colors() {
        let colors = [
            super::fstype_color(Some("vfat")),
            super::fstype_color(Some("ext4")),
            super::fstype_color(Some("btrfs")),
            super::fstype_color(Some("xfs")),
            super::fstype_color(Some("swap")),
            super::fstype_color(Some("LVM2_member")),
            super::fstype_color(Some("ntfs")),
        ];
        for (index, color) in colors.iter().enumerate() {
            assert!(
                !colors[..index].contains(color),
                "category color {index} duplicates an earlier category"
            );
        }
    }
}
