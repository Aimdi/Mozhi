/// Compact "improve my writing" UI for text selected in another app
/// (Android `PROCESS_TEXT` "Improve with Mozhi"): the selection proofread
/// with the Proofread tab's AI engine, the changes highlighted, Replace /
/// Copy / Open in Proofread.
///
/// Entry point: `showQuickImprove(context, text: ...)` (or
/// `QuickImproveSheet` to embed the content). On Android it runs in the
/// translucent quick translate window (`QuickTranslateHost`).
library;

export 'cubit/quick_improve_cubit.dart';
export 'models/improve_engines.dart';
export 'view/quick_improve_sheet.dart';
export 'widgets/widgets.dart';
