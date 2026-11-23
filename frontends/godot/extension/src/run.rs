//! Text drawn as shaped runs instead of single glyphs: consecutive ASCII
//! cells with one style and color, shaped together so the font's ligature
//! substitutions apply.
//!
//! Each glyph is anchored to its own cell because the cell grid uses the
//! ceiled advance and pen-advanced drawing drifts off it.

use std::{collections::HashMap, rc::Rc};

use godot::classes::text_server::Direction;
use godot::classes::{Font, TextLine, TextServerManager};
use godot::prelude::*;

/// Snap shared cell edges in the final window's pixels. Rounding each origin
/// independently avoids accumulating a half-pixel error across an entire row.
#[derive(Clone, Copy, Default, PartialEq)]
pub struct PixelGrid {
    pub density: f32,
    pub phase: Vector2,
}

impl PixelGrid {
    pub fn point(self, at: Vector2) -> Vector2 {
        if self.density <= 0.0 { return at; }
        ((at * self.density + self.phase).round() - self.phase) / self.density
    }

    /// Invert the rounded edges, including the exact half-pixel tie. A cell
    /// begins at round(origin + n * step). Find the last such edge at or
    /// before the pointer's pixel without perturbing coordinates by epsilon.
    pub fn cell(self, point: Vector2, origin: f32, size: Vector2) -> Vector2 {
        if self.density <= 0.0 { return ((point - Vector2::splat(origin)) / size).floor(); }
        let axis = |at: f32, step: f32, phase: f32| {
            let density = f64::from(self.density);
            let phase = f64::from(phase);
            let pixel = (f64::from(at) * density + phase).floor();
            (((pixel + 0.5 - phase - f64::from(origin) * density) / (f64::from(step) * density)).ceil() - 1.0) as f32
        };
        Vector2::new(axis(point.x, size.x, self.phase.x), axis(point.y, size.y, self.phase.y))
    }

    pub fn rect(self, rect: Rect2) -> Rect2 {
        if self.density <= 0.0 { return rect; }
        let start = self.point(rect.position);
        Rect2::new(start, self.point(rect.end()) - start)
    }
}

/// A run being collected while walking a row, at cell-left `x`.
#[derive(Clone)]
pub struct Run {
    pub text: String,
    pub style: u8,
    pub fg: Color,
    pub x: f32,
}

struct Glyph {
    cell: i64,
    index: i64,
    font_rid: Rid,
    font_size: i64,
    offset: Vector2,
}

struct Entry {
    glyphs: Vec<Glyph>,
    used: u64,
}

/// TextLine stores font RIDs. A snapshot must also own the font resource so
/// these RIDs stay valid after its terminal closes or changes font.
pub struct Cluster {
    line: Gd<TextLine>,
    _font: Gd<Font>,
    pub ink: Rect2,
    ascent: f32,
}

impl Cluster {
    fn new(font: &Gd<Font>, text: &str, size: i32) -> Self {
        let mut line = TextLine::new_gd();
        line.add_string(text, font, size);
        let ascent = line.get_line_ascent(); // Complete the layout used by draw().
        let mut bounds: Option<Rect2> = None;
        if let Some(ts) = TextServerManager::singleton().get_primary_interface() {
            let mut pen = Vector2::ZERO;
            for g in ts.shaped_text_get_glyphs(line.get_rid()).iter_shared() {
                let rid: Rid = g.at("font_rid").to();
                let index: i64 = g.at("index").to();
                let size: i64 = g.at("font_size").to();
                let offset: Vector2 = g.at("offset").to();
                let advance: f32 = g.at("advance").to();
                let glyph = crate::flight_grid::glyph_ink(&ts, rid, size, index);
                for _ in 0..g.at("repeat").to::<i64>() {
                    if glyph.has_area() {
                        let rect = Rect2::new(pen + offset + glyph.position, glyph.size);
                        bounds = Some(bounds.map_or(rect, |b| b.merge(rect)));
                    }
                    pen.x += advance;
                }
            }
        }
        Self {
            line,
            _font: font.clone(),
            ink: bounds.unwrap_or_default(),
            ascent,
        }
    }

    pub fn draw(
        &self,
        canvas: Rid,
        baseline: Vector2,
        color: Color,
        density: f32,
        outline: i32,
        edge: Color,
    ) {
        let top = baseline - Vector2::DOWN * self.ascent;
        if outline > 0 {
            self.line
                .draw_outline_ex(canvas, top)
                .outline_size(outline)
                .color(edge)
                .oversampling(density)
                .done();
        }
        self.line
            .draw_ex(canvas, top)
            .color(color)
            .oversampling(density)
            .done();
    }
}

/// Shaped runs keyed on content per style font, kept exactly as large as
/// the last repaint. Scrolled rows keep the same content, so they hit.
pub struct RunCache {
    entries: [HashMap<String, Entry>; 4],
    generation: u64,
    clusters: HashMap<(InstanceId, String, i32), (Rc<Cluster>, u64)>,
}

impl RunCache {
    pub fn new() -> Self {
        Self {
            entries: Default::default(),
            generation: 0,
            clusters: HashMap::new(),
        }
    }

    /// Draw one run with its first baseline at `(run.x, baseline)`. A
    /// single cell skips shaping, alone it has no ligature context.
    pub fn draw(
        &mut self,
        canvas: Rid,
        font: &Gd<Font>,
        run: Run,
        baseline: f32,
        cell_w: f32,
        font_size: i32,
        raster_scale: f32,
        grid: PixelGrid,
        outline_width: i32,
        outline_color: Color,
        mut flight: Option<&mut crate::flight_grid::FlightGrid>,
    ) {
        let glyph_at = |glyph: &Glyph| {
            grid.point(Vector2::new(run.x + glyph.cell as f32 * cell_w, baseline)) + glyph.offset
        };
        let Some(ts) = TextServerManager::singleton().get_primary_interface() else {
            return;
        };
        let generation = self.generation;
        let entry = self.entries[run.style as usize]
            .entry(run.text)
            .or_insert_with_key(|text| Entry {
                glyphs: shape(text, font, font_size),
                used: generation,
            });
        entry.used = generation;
        // TextServer caches outline glyph masks alongside the normal glyph.
        // Draw the complete outline pass first, so a neighboring outline never
        // paints over another glyph's foreground or selected foreground.
        if outline_width > 0 {
            for glyph in &entry.glyphs {
                ts.font_draw_glyph_outline_ex(
                    glyph.font_rid, canvas, glyph.font_size, i64::from(outline_width),
                    glyph_at(glyph), glyph.index,
                ).color(outline_color).oversampling(raster_scale).done();
            }
        }
        for glyph in &entry.glyphs {
            let at = glyph_at(glyph);
            if let Some(cuts) = flight.as_deref_mut() {
                let head = Vector2::new(run.x + glyph.cell as f32 * cell_w, baseline);
                cuts.glyph(&ts, head, at, glyph.font_rid, glyph.font_size, glyph.index, outline_width);
            }
            ts.font_draw_glyph_ex(
                glyph.font_rid,
                canvas,
                glyph.font_size,
                at,
                glyph.index,
            )
            .color(run.fg)
            .oversampling(raster_scale)
            .done();
        }
    }

    /// Font.draw_string uses a TextLine internally. Retain that same layout
    /// for a whole grapheme so capture can reuse its bounds and its draw.
    pub fn cluster(&mut self, font: &Gd<Font>, text: String, size: i32) -> Rc<Cluster> {
        let entry = self.clusters.entry((font.instance_id(), text, size))
            .or_insert_with_key(|(_, text, _)| (Rc::new(Cluster::new(font, text, size)), self.generation));
        entry.1 = self.generation;
        entry.0.clone()
    }

    /// Drop runs not drawn since the last call.
    pub fn end_frame(&mut self) {
        let generation = self.generation;
        for map in &mut self.entries {
            map.retain(|_, entry| entry.used == generation);
        }
        self.clusters.retain(|_, entry| entry.1 == generation);
        self.generation += 1;
    }
}

/// Shape through the TextServer and keep each glyph with the cell it
/// starts in, from its cluster. ASCII runs are one char per cell.
fn shape(text: &str, font: &Gd<Font>, font_size: i32) -> Vec<Glyph> {
    let Some(mut ts) = TextServerManager::singleton().get_primary_interface() else {
        return Vec::new();
    };
    let rid = ts.create_shaped_text_ex().direction(Direction::LTR).done();
    ts.shaped_text_add_string_ex(rid, text, &font.get_rids(), font_size as i64)
        .opentype_features(&font.get_opentype_features())
        .done();
    let glyphs = ts
        .shaped_text_get_glyphs(rid)
        .iter_shared()
        .map(|g| {
            let get = |key: &str| g.get(key).unwrap_or_default();
            Glyph {
                cell: get("start").try_to().unwrap_or(0),
                index: get("index").try_to().unwrap_or(0),
                font_rid: get("font_rid").try_to().unwrap_or(Rid::Invalid),
                font_size: get("font_size").try_to().unwrap_or(font_size as i64),
                offset: get("offset").try_to().unwrap_or(Vector2::ZERO),
            }
        })
        .collect();
    ts.free_rid(rid);
    glyphs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fractional_cell_edges_share_pixels_without_width_drift() {
        for density in [1.25, 1.5, 1.75] {
            let phase = Vector2::new(0.25, 0.75);
            let grid = PixelGrid { density, phase };
            for col in 0..200 {
                let at = Vector2::new(col as f32 * 11.0, 4.0);
                let cell = grid.rect(Rect2::new(at, Vector2::new(11.0, 17.0)));
                let px = cell.position * density + phase;
                assert!((px - px.round()).length() < 0.001);
                assert!((cell.end().x - grid.point(at + Vector2::new(11.0, 0.0)).x).abs() < 0.001);
                assert!((px.x - (at.x * density + phase.x)).abs() <= 0.501);
                for pixel in [px.x, (cell.end().x * density + phase.x).round() - 1.0] {
                    let mouse = Vector2::new((pixel + 0.1 - phase.x) / density, at.y);
                    assert_eq!(grid.cell(mouse, 0.0, Vector2::new(11.0, 17.0)).x as usize, col);
                }
            }
        }
    }
}
