import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:epub_view/src/data/epub_cfi_reader.dart';
import 'package:epub_view/src/data/epub_parser.dart';
import 'package:epub_view/src/data/models/chapter.dart';
import 'package:epub_view/src/data/models/chapter_view_value.dart';
import 'package:epub_view/src/data/models/paragraph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

export 'package:epubx/epubx.dart' hide Image;

part '../epub_controller.dart';
part '../helpers/epub_view_builders.dart';

const _minTrailingEdge = 0.55;
const _minLeadingEdge = -0.05;

typedef ExternalLinkPressed = void Function(String href);
typedef TextSelectedCallback = void Function(
    String selectedText, int paragraphIndex);

// Add highlight model
class TextHighlight {
  final String text;
  final int paragraphIndex;
  final Color color;
  final String? note;
  final DateTime createdAt;

  TextHighlight({
    required this.text,
    required this.paragraphIndex,
    required this.color,
    this.note,
    required this.createdAt,
  });
}

class EpubView extends StatefulWidget {
  const EpubView({
    required this.controller,
    this.onExternalLinkPressed,
    this.onChapterChanged,
    this.onDocumentLoaded,
    this.onDocumentError,
    this.onTextSelected, // New callback for text selection
    this.builders = const EpubViewBuilders<DefaultBuilderOptions>(
      options: DefaultBuilderOptions(),
    ),
    this.shrinkWrap = false,
    this.scrollDirection = Axis.vertical, // New parameter for scroll direction
    this.pageSnapping =
        false, // New parameter for page snapping in horizontal mode
    Key? key,
  }) : super(key: key);

  final EpubController controller;
  final ExternalLinkPressed? onExternalLinkPressed;
  final TextSelectedCallback? onTextSelected;
  final bool shrinkWrap;
  final Axis scrollDirection; // New: scroll direction
  final bool pageSnapping; // New: page snapping for horizontal scroll
  final void Function(EpubChapterViewValue? value)? onChapterChanged;

  /// Called when a document is loaded
  final void Function(EpubBook document)? onDocumentLoaded;

  /// Called when a document loading error
  final void Function(Exception? error)? onDocumentError;

  /// Builders
  final EpubViewBuilders builders;

  @override
  State<EpubView> createState() => _EpubViewState();
}

class _EpubViewState extends State<EpubView> {
  Exception? _loadingError;
  ItemScrollController? _itemScrollController;
  ItemPositionsListener? _itemPositionListener;
  List<EpubChapter> _chapters = [];
  List<Paragraph> _paragraphs = [];
  EpubCfiReader? _epubCfiReader;
  EpubChapterViewValue? _currentValue;
  final _chapterIndexes = <int>[];

  // New: Highlighting functionality
  final List<TextHighlight> _highlights = [];
  final Map<int, List<TextHighlight>> _paragraphHighlights = {};

  EpubController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _itemScrollController = ItemScrollController();
    _itemPositionListener = ItemPositionsListener.create();
    _controller._attach(this);
    _controller.loadingState.addListener(() {
      switch (_controller.loadingState.value) {
        case EpubViewLoadingState.loading:
          break;
        case EpubViewLoadingState.success:
          widget.onDocumentLoaded?.call(_controller._document!);
          break;
        case EpubViewLoadingState.error:
          widget.onDocumentError?.call(_loadingError);
          break;
      }

      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _itemPositionListener!.itemPositions.removeListener(_changeListener);
    _controller._detach();
    super.dispose();
  }

  Future<bool> _init() async {
    if (_controller.isBookLoaded.value) {
      return true;
    }
    _chapters = parseChapters(_controller._document!);
    final parseParagraphsResult =
        parseParagraphs(_chapters, _controller._document!.Content);
    _paragraphs = parseParagraphsResult.flatParagraphs;
    _chapterIndexes.addAll(parseParagraphsResult.chapterIndexes);

    _epubCfiReader = EpubCfiReader.parser(
      cfiInput: _controller.epubCfi,
      chapters: _chapters,
      paragraphs: _paragraphs,
    );
    _itemPositionListener!.itemPositions.addListener(_changeListener);
    _controller.isBookLoaded.value = true;

    return true;
  }

  void _changeListener() {
    if (_paragraphs.isEmpty ||
        _itemPositionListener!.itemPositions.value.isEmpty) {
      return;
    }
    final position = _itemPositionListener!.itemPositions.value.first;
    final chapterIndex = _getChapterIndexBy(
      positionIndex: position.index,
      trailingEdge: position.itemTrailingEdge,
      leadingEdge: position.itemLeadingEdge,
    );
    final paragraphIndex = _getParagraphIndexBy(
      positionIndex: position.index,
      trailingEdge: position.itemTrailingEdge,
      leadingEdge: position.itemLeadingEdge,
    );
    _currentValue = EpubChapterViewValue(
      chapter: chapterIndex >= 0 ? _chapters[chapterIndex] : null,
      chapterNumber: chapterIndex + 1,
      paragraphNumber: paragraphIndex + 1,
      position: position,
    );
    _controller.currentValueListenable.value = _currentValue;
    widget.onChapterChanged?.call(_currentValue);
  }

  void _gotoEpubCfi(
    String? epubCfi, {
    double alignment = 0,
    Duration duration = const Duration(milliseconds: 250),
    Curve curve = Curves.linear,
  }) {
    _epubCfiReader?.epubCfi = epubCfi;
    final index = _epubCfiReader?.paragraphIndexByCfiFragment;

    if (index == null) {
      return;
    }

    _itemScrollController?.scrollTo(
      index: index,
      duration: duration,
      alignment: alignment,
      curve: curve,
    );
  }

  void _onLinkPressed(String href) {
    if (href.contains('://')) {
      widget.onExternalLinkPressed?.call(href);
      return;
    }

    // Chapter01.xhtml#ph1_1 -> [ph1_1, Chapter01.xhtml] || [ph1_1]
    String? hrefIdRef;
    String? hrefFileName;

    if (href.contains('#')) {
      final dividedHref = href.split('#');
      if (dividedHref.length == 1) {
        hrefIdRef = href;
      } else {
        hrefFileName = dividedHref[0];
        hrefIdRef = dividedHref[1];
      }
    } else {
      hrefFileName = href;
    }

    if (hrefIdRef == null) {
      final chapter = _chapterByFileName(hrefFileName);
      if (chapter != null) {
        final cfi = _epubCfiReader?.generateCfiChapter(
          book: _controller._document,
          chapter: chapter,
          additional: ['/4/2'],
        );

        _gotoEpubCfi(cfi);
      }
      return;
    } else {
      final paragraph = _paragraphByIdRef(hrefIdRef);
      final chapter =
          paragraph != null ? _chapters[paragraph.chapterIndex] : null;

      if (chapter != null && paragraph != null) {
        final paragraphIndex =
            _epubCfiReader?.getParagraphIndexByElement(paragraph.element);
        final cfi = _epubCfiReader?.generateCfi(
          book: _controller._document,
          chapter: chapter,
          paragraphIndex: paragraphIndex,
        );

        _gotoEpubCfi(cfi);
      }

      return;
    }
  }

  // New: Add highlight functionality
  void addHighlight(String text, int paragraphIndex,
      {Color? color, String? note}) {
    final highlight = TextHighlight(
      text: text,
      paragraphIndex: paragraphIndex,
      color: color ?? Colors.yellow.withOpacity(0.3),
      note: note,
      createdAt: DateTime.now(),
    );

    _highlights.add(highlight);
    _paragraphHighlights.putIfAbsent(paragraphIndex, () => []).add(highlight);

    setState(() {});
  }

  void removeHighlight(TextHighlight highlight) {
    _highlights.remove(highlight);
    _paragraphHighlights[highlight.paragraphIndex]?.remove(highlight);
    if (_paragraphHighlights[highlight.paragraphIndex]?.isEmpty ?? false) {
      _paragraphHighlights.remove(highlight.paragraphIndex);
    }
    setState(() {});
  }

  void _onTextSelected(String selectedText, int paragraphIndex) {
    widget.onTextSelected?.call(selectedText, paragraphIndex);
  }

  Paragraph? _paragraphByIdRef(String idRef) =>
      _paragraphs.firstWhereOrNull((paragraph) {
        if (paragraph.element.id == idRef) {
          return true;
        }

        return paragraph.element.children.isNotEmpty &&
            paragraph.element.children[0].id == idRef;
      });

  EpubChapter? _chapterByFileName(String? fileName) =>
      _chapters.firstWhereOrNull((chapter) {
        if (fileName != null) {
          if (chapter.ContentFileName!.contains(fileName)) {
            return true;
          } else {
            return false;
          }
        }
        return false;
      });

  int _getChapterIndexBy({
    required int positionIndex,
    double? trailingEdge,
    double? leadingEdge,
  }) {
    final posIndex = _getAbsParagraphIndexBy(
      positionIndex: positionIndex,
      trailingEdge: trailingEdge,
      leadingEdge: leadingEdge,
    );
    final index = posIndex >= _chapterIndexes.last
        ? _chapterIndexes.length
        : _chapterIndexes.indexWhere((chapterIndex) {
            if (posIndex < chapterIndex) {
              return true;
            }
            return false;
          });

    return index - 1;
  }

  int _getParagraphIndexBy({
    required int positionIndex,
    double? trailingEdge,
    double? leadingEdge,
  }) {
    final posIndex = _getAbsParagraphIndexBy(
      positionIndex: positionIndex,
      trailingEdge: trailingEdge,
      leadingEdge: leadingEdge,
    );

    final index = _getChapterIndexBy(positionIndex: posIndex);

    if (index == -1) {
      return posIndex;
    }

    return posIndex - _chapterIndexes[index];
  }

  int _getAbsParagraphIndexBy({
    required int positionIndex,
    double? trailingEdge,
    double? leadingEdge,
  }) {
    int posIndex = positionIndex;
    if (trailingEdge != null &&
        leadingEdge != null &&
        trailingEdge < _minTrailingEdge &&
        leadingEdge < _minLeadingEdge) {
      posIndex += 1;
    }

    return posIndex;
  }

  static Widget _chapterDividerBuilder(EpubChapter chapter) => Container(
        height: 56,
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: Color(0x24000000),
        ),
        alignment: Alignment.centerLeft,
        child: Text(
          chapter.Title ?? '',
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  static Widget _chapterBuilder(
    BuildContext context,
    EpubViewBuilders builders,
    EpubBook document,
    List<EpubChapter> chapters,
    List<Paragraph> paragraphs,
    int index,
    int chapterIndex,
    int paragraphIndex,
    ExternalLinkPressed onExternalLinkPressed,
  ) {
    if (paragraphs.isEmpty) {
      return Container();
    }

    final defaultBuilder = builders as EpubViewBuilders<DefaultBuilderOptions>;
    final options = defaultBuilder.options;

    return Column(
      children: <Widget>[
        if (chapterIndex >= 0 && paragraphIndex == 0)
          builders.chapterDividerBuilder(chapters[chapterIndex]),
        Html(
          data: paragraphs[index].element.outerHtml,
          onLinkTap: (href, _, __) => onExternalLinkPressed(href!),
          style: {
            'html': Style(
              padding: HtmlPaddings.only(
                top: (options.paragraphPadding as EdgeInsets?)?.top,
                right: (options.paragraphPadding as EdgeInsets?)?.right,
                bottom: (options.paragraphPadding as EdgeInsets?)?.bottom,
                left: (options.paragraphPadding as EdgeInsets?)?.left,
              ),
            ).merge(Style.fromTextStyle(options.textStyle)),
          },
          extensions: [
            TagExtension(
              tagsToExtend: {"img"},
              builder: (imageContext) {
                final url =
                    imageContext.attributes['src']!.replaceAll('../', '');
                final content = Uint8List.fromList(
                    document.Content!.Images![url]!.Content!);
                return Image(
                  image: MemoryImage(content),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildChapterWithHighlights(
    BuildContext context,
    EpubViewBuilders builders,
    EpubBook document,
    List<EpubChapter> chapters,
    List<Paragraph> paragraphs,
    int index,
    int chapterIndex,
    int paragraphIndex,
    ExternalLinkPressed onExternalLinkPressed,
  ) {
    if (paragraphs.isEmpty) {
      return Container();
    }

    final defaultBuilder = builders as EpubViewBuilders<DefaultBuilderOptions>;
    final options = defaultBuilder.options;

    // Get highlights for this paragraph
    final highlights = _paragraphHighlights[index] ?? [];

    return Column(
      children: <Widget>[
        if (chapterIndex >= 0 && paragraphIndex == 0)
          builders.chapterDividerBuilder(chapters[chapterIndex]),
        SelectableText.rich(
          TextSpan(
            children: _buildHighlightedText(
              paragraphs[index].element.text ?? '',
              highlights,
            ),
          ),
          onSelectionChanged: (selection, cause) {
            if (selection.isCollapsed) return;
            final selectedText = paragraphs[index]
                    .element
                    .text
                    .substring(selection.start, selection.end) ??
                '';
            if (selectedText.isNotEmpty) {
              _onTextSelected(selectedText, index);
            }
          },
          style: options.textStyle,
        ),
      ],
    );
  }

  // New: Build highlighted text spans
  List<TextSpan> _buildHighlightedText(
      String text, List<TextHighlight> highlights) {
    if (highlights.isEmpty) {
      return [TextSpan(text: text)];
    }

    final spans = <TextSpan>[];
    int currentIndex = 0;

    // Sort highlights by position in text
    highlights
        .sort((a, b) => text.indexOf(a.text).compareTo(text.indexOf(b.text)));

    for (final highlight in highlights) {
      final highlightIndex = text.indexOf(highlight.text, currentIndex);

      if (highlightIndex == -1) continue;

      // Add text before highlight
      if (highlightIndex > currentIndex) {
        spans.add(TextSpan(text: text.substring(currentIndex, highlightIndex)));
      }

      // Add highlighted text
      spans.add(TextSpan(
        text: highlight.text,
        style: TextStyle(backgroundColor: highlight.color),
      ));

      currentIndex = highlightIndex + highlight.text.length;
    }

    // Add remaining text
    if (currentIndex < text.length) {
      spans.add(TextSpan(text: text.substring(currentIndex)));
    }

    return spans;
  }

  Widget _buildLoaded(BuildContext context) {
    if (widget.scrollDirection == Axis.horizontal) {
      return _buildHorizontalScroll(context);
    } else {
      return _buildVerticalScroll(context);
    }
  }

  Widget _buildVerticalScroll(BuildContext context) {
    return ScrollablePositionedList.builder(
      shrinkWrap: widget.shrinkWrap,
      scrollDirection: Axis.vertical,
      initialScrollIndex: _epubCfiReader!.paragraphIndexByCfiFragment ?? 0,
      itemCount: _paragraphs.length,
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionListener,
      itemBuilder: (BuildContext context, int index) {
        return _buildChapterWithHighlights(
          context,
          widget.builders,
          widget.controller._document!,
          _chapters,
          _paragraphs,
          index,
          _getChapterIndexBy(positionIndex: index),
          _getParagraphIndexBy(positionIndex: index),
          _onLinkPressed,
        );
      },
    );
  }

List<List<int>> _calculatePages(BuildContext context) {
  final screenHeight = MediaQuery.of(context).size.height;
  final availableHeight = screenHeight - 100; // Account for padding and safe area
  final pages = <List<int>>[];
  var currentPage = <int>[];
  var currentHeight = 0.0;
  
  for (int i = 0; i < _paragraphs.length; i++) {
    // Estimate paragraph height (this is a rough estimate)
    final paragraphText = _paragraphs[i].element.text ?? '';
    final estimatedHeight = (paragraphText.length / 80) * 24.0 + 16.0; // Rough calculation
    
    if (currentHeight + estimatedHeight > availableHeight && currentPage.isNotEmpty) {
      pages.add(currentPage);
      currentPage = [i];
      currentHeight = estimatedHeight;
    } else {
      currentPage.add(i);
      currentHeight += estimatedHeight;
    }
  }
  
  if (currentPage.isNotEmpty) {
    pages.add(currentPage);
  }
  
  return pages;
}

Widget _buildHorizontalScroll(BuildContext context) {
  if (widget.pageSnapping) {
    final pages = _calculatePages(context);
    
    return PageView.builder(
      physics: const PageScrollPhysics(),
      scrollDirection: Axis.horizontal,
      itemCount: pages.length,
      itemBuilder: (BuildContext context, int pageIndex) {
        return Container(
          width: double.infinity,
          height: double.infinity,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: pages[pageIndex].map((paragraphIndex) {
                      return _buildChapterWithHighlights(
                        context,
                        widget.builders,
                        widget.controller._document!,
                        _chapters,
                        _paragraphs,
                        paragraphIndex,
                        _getChapterIndexBy(positionIndex: paragraphIndex),
                        _getParagraphIndexBy(positionIndex: paragraphIndex),
                        _onLinkPressed,
                      );
                    }).toList(),
                  ),
                ),
              ),
              // Optional: Add page indicator
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${pageIndex + 1} / ${pages.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  } else {
    return ScrollablePositionedList.builder(
      shrinkWrap: widget.shrinkWrap,
      scrollDirection: Axis.horizontal,
      initialScrollIndex: _epubCfiReader!.paragraphIndexByCfiFragment ?? 0,
      itemCount: _paragraphs.length,
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionListener,
      itemBuilder: (BuildContext context, int index) {
        return Container(
          width: MediaQuery.of(context).size.width,
          height: double.infinity,
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: _buildChapterWithHighlights(
              context,
              widget.builders,
              widget.controller._document!,
              _chapters,
              _paragraphs,
              index,
              _getChapterIndexBy(positionIndex: index),
              _getParagraphIndexBy(positionIndex: index),
              _onLinkPressed,
            ),
          ),
        );
      },
    );
  }
}

  static Widget _builder(
    BuildContext context,
    EpubViewBuilders builders,
    EpubViewLoadingState state,
    WidgetBuilder loadedBuilder,
    Exception? loadingError,
  ) {
    final Widget content = () {
      switch (state) {
        case EpubViewLoadingState.loading:
          return KeyedSubtree(
            key: const Key('epubx.root.loading'),
            child: builders.loaderBuilder?.call(context) ?? const SizedBox(),
          );
        case EpubViewLoadingState.error:
          return KeyedSubtree(
            key: const Key('epubx.root.error'),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: builders.errorBuilder?.call(context, loadingError!) ??
                  Center(child: Text(loadingError.toString())),
            ),
          );
        case EpubViewLoadingState.success:
          return KeyedSubtree(
            key: const Key('epubx.root.success'),
            child: loadedBuilder(context),
          );
      }
    }();

    final defaultBuilder = builders as EpubViewBuilders<DefaultBuilderOptions>;
    final options = defaultBuilder.options;

    return AnimatedSwitcher(
      duration: options.loaderSwitchDuration,
      transitionBuilder: options.transitionBuilder,
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.builders.builder(
      context,
      widget.builders,
      _controller.loadingState.value,
      _buildLoaded,
      _loadingError,
    );
  }
}
