//! Fixed cuts in the foreground snapshot. A cut through ink joins the cells on
//! both sides, before semantic layers or the whole-letter/dust split are chosen.
use godot::classes::{Font, TextServer, TextServerManager};
use godot::prelude::*;
use std::collections::{BTreeMap, HashMap};

#[derive(Clone, Copy)]
pub struct FlightPiece {
    pub rect: Rect2i,
    pub cp: u32,
    pub styled: bool,
    pub font: i32,
}

pub struct FlightGrid {
    origin: Vector2,
    step: Vector2,
    ascent: f32,
    cells: Vec<FlightPiece>,
    glyph_bounds: HashMap<(Rid, i64, i64), Rect2>,
    char_bounds: HashMap<(InstanceId, u32, i32), Rect2>,
    // Only overhangs need a lookup. Ordinary cells follow the VT's width.
    overhangs: HashMap<Vector2i, Rect2i>,
}

impl FlightGrid {
    pub fn new(pad: f32, step: Vector2, ascent: f32) -> Self {
        Self {
            origin: Vector2::splat(pad),
            step,
            ascent,
            cells: Vec::new(),
            glyph_bounds: HashMap::new(),
            char_bounds: HashMap::new(),
            overhangs: HashMap::new(),
        }
    }

    pub fn cell(&mut self, col: u16, row: u16, width: i32, cp: u32, styled: bool, font: i32) {
        self.cells.push(FlightPiece {
            rect: Rect2i::from_components(col.into(), row.into(), width, 1),
            cp,
            styled,
            font,
        });
    }

    pub fn character(
        &mut self,
        font: &Gd<Font>,
        cp: u32,
        size: i32,
        outline: i32,
        head: Vector2,
        at: Vector2,
    ) {
        let bounds = *self
            .char_bounds
            .entry((font.instance_id(), cp, size))
            .or_insert_with(|| {
                let Some(ts) = TextServerManager::singleton().get_primary_interface() else {
                    return Rect2::default();
                };
                for rid in font.get_rids().iter_shared() {
                    if ts.font_has_char(rid, i64::from(cp)) {
                        let index = ts.font_get_glyph_index(rid, size.into(), cp.into(), 0);
                        return glyph_ink(&ts, rid, size.into(), index);
                    }
                }
                Rect2::default()
            });
        self.place(head, at, bounds, outline);
    }

    pub fn glyph(
        &mut self,
        ts: &TextServer,
        head: Vector2,
        at: Vector2,
        rid: Rid,
        size: i64,
        index: i64,
        outline: i32,
    ) {
        let bounds = *self
            .glyph_bounds
            .entry((rid, size, index))
            .or_insert_with(|| glyph_ink(ts, rid, size, index));
        self.place(head, at, bounds, outline);
    }

    fn place(&mut self, head: Vector2, at: Vector2, mut bounds: Rect2, outline: i32) {
        if bounds.has_area() {
            bounds.position += at;
            self.ink(head, bounds.grow(outline as f32));
        }
    }

    pub fn ink(&mut self, baseline: Vector2, ink: Rect2) {
        if !ink.has_area() {
            return;
        }
        let head = ((baseline - self.origin - Vector2::DOWN * self.ascent) / self.step)
            .round()
            .to_vector2i();
        let start = ((ink.position - self.origin) / self.step)
            .floor()
            .to_vector2i()
            .coord_min(head);
        let end = ((ink.end() - self.origin) / self.step)
            .ceil()
            .to_vector2i()
            .coord_max(head + Vector2i::ONE);
        if end - start != Vector2i::ONE {
            let rect = Rect2i::new(start, end - start);
            self.overhangs
                .entry(head)
                .and_modify(|r| *r = r.merge(rect))
                .or_insert(rect);
        }
    }

    pub fn pieces(self) -> Vec<FlightPiece> {
        // Each occupied row indexes disjoint intervals by their left edge.
        // Absorb colliding owners before inserting the union. Long overhangs
        // cost one interval per row, even when a whole styled run joins up.
        let mut rows = HashMap::<i32, BTreeMap<i32, usize>>::new();
        let mut pieces: Vec<Option<FlightPiece>> = Vec::with_capacity(self.cells.len());
        for mut cell in self.cells {
            if let Some(rect) = self.overhangs.get(&cell.rect.position) {
                cell.rect = cell.rect.merge(*rect);
            }
            let mut rect = cell.rect;
            loop {
                let overlap = (rect.position.y..rect.end().y).find_map(|y| {
                    // Of intervals starting before our right edge, only the
                    // rightmost needs checking to find an intersection.
                    let (_, &i) = rows.get(&y)?.range(..rect.end().x).next_back()?;
                    (pieces[i]?.rect.end().x > rect.position.x).then_some(i)
                });
                let Some(i) = overlap else { break };
                let prev = pieces[i].take().unwrap();
                for y in prev.rect.position.y..prev.rect.end().y {
                    rows.get_mut(&y).unwrap().remove(&prev.rect.position.x);
                }
                rect = rect.merge(prev.rect);
                if cell.cp <= 32 {
                    cell = prev;
                }
            }
            cell.rect = rect;
            for y in rect.position.y..rect.end().y {
                rows.entry(y)
                    .or_default()
                    .insert(rect.position.x, pieces.len());
            }
            pieces.push(Some(cell));
        }
        pieces.into_iter().flatten().collect()
    }

    pub fn occupied_count(&self) -> usize {
        self.cells.len()
    }
}

impl FlightPiece {
    pub fn span(&self) -> Vector4i {
        let r = self.rect;
        Vector4i::new(r.position.x, r.position.y, r.size.x, r.size.y)
    }
}

/// Bounds of the bitmap which TextServer already uses to draw this glyph.
/// Its scalable-font atlas has a transparent one-texel filtering gutter.
/// Convert that texel to logical units too (bitmap emoji strikes are scaled).
pub(crate) fn glyph_ink(ts: &godot::classes::TextServer, rid: Rid, size: i64, index: i64) -> Rect2 {
    if !rid.is_valid() || index == 0 {
        return Rect2::default();
    }
    let strike = Vector2i::new(size as i32, 0);
    let extent = ts.font_get_glyph_size(rid, strike, index);
    if extent.x <= 0.0 || extent.y <= 0.0 {
        return Rect2::default();
    }
    let offset = ts.font_get_glyph_offset(rid, strike, index);
    let uv = ts.font_get_glyph_uv_rect(rid, strike, index);
    let gutter = if uv.has_area() {
        extent / uv.size
    } else {
        Vector2::ZERO
    };
    Rect2::new(offset + gutter, extent - gutter * 2.0)
}
