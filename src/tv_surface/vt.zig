const abi = @import("../vt_publication/abi.zig");
const publication = @import("../vt_publication/publication.zig");

pub const SourceRgb = abi.SourceRgb;
pub const SourceColor = abi.SourceColor;
pub const SourceColors = abi.SourceColors;
pub const SourceCellFlags = abi.SourceCellFlags;
pub const SourceCellAttrs = abi.SourceCellAttrs;
pub const SourceCell = abi.SourceCell;
pub const SourceSelectionPoint = abi.SourceSelectionPoint;
pub const SourceSelection = abi.SourceSelection;
pub const SourceCursor = abi.SourceCursor;
pub const VtSnapshot = publication.VtSnapshot;
pub const PublicationSource = publication.PublicationSource;

pub const validateSourceCell = abi.validateSourceCell;
pub const validateSourceCells = abi.validateSourceCells;
pub const sourceColorValid = abi.sourceColorValid;
pub const underlineStyleValid = abi.underlineStyleValid;
pub const validatePublicationSurfaceResult = abi.validatePublicationSurfaceResult;
pub const validatePublicationSourceBoundary = publication.validatePublicationSourceBoundary;
pub const ownedSourceFromSurfaceResult = publication.ownedSourceFromSurfaceResult;
pub const testSourceFromSnapshot = publication.testSourceFromSnapshot;
pub const ownedTestSource = publication.ownedTestSource;
