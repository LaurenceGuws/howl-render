const publication_damage = @import("../damage/publication_damage.zig");

pub const validateDirtySource = publication_damage.validateDirtySource;
pub const canonicalizeDirtyMetadata = publication_damage.canonicalizeDirtyMetadata;
pub const cursorPresentationChanged = publication_damage.cursorPresentationChanged;
pub const colorPresentationChanged = publication_damage.colorPresentationChanged;
pub const setSourceCursorBlinkVisible = publication_damage.setSourceCursorBlinkVisible;
pub const sameSnapshotToken = publication_damage.sameSnapshotToken;
pub const samePublicationSource = publication_damage.samePublicationSource;
pub const classifyDirty = publication_damage.classifyDirty;
