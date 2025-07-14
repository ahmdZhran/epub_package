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
import 'package:flutter/services.dart'; // Added for haptic feedback

export 'package:epubx/epubx.dart' hide Image;

part '../epub_controller.dart';
part '../helpers/epub_view_builders.dart';

const _minTrailingEdge = 0.55;
const _minLeadingEdge = -0.05;

typedef ExternalLinkPressed = void Function(String href);
typedef TextSelectedCallback = void Function(String selectedText, int paragraphIndex);

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

// Page content model
class _PageContent {
  final List<int> paragraphIndexes;
  final double estimatedHeight;

  _PageContent({required this.paragraphIndexes, required this.estimatedHeight});
}

class EpubView extends StatefulWidget {
  const EpubView({
    required this.controller,
    this.onExternalLinkPressed,
    this.onChapterChanged,
    this.onDocumentLoaded,
    this.onDocumentError,
    this.onTextSelected,
    this.builders = const EpubViewBuilders<DefaultBuilderOptions>(
      options: DefaultBuilderOptions(),
    ),
    this.shrinkWrap = false,
    this.scrollDirection = Axis.vertical,
    this.pageSnapping = false,
    Key? key,
  }) : super(key: key);

  final EpubController controller;
  final ExternalLinkPressed? onExternalLinkPressed;
  final TextSelectedCallback? onTextSelected;
  final bool shrinkWrap;
  final Axis scrollDirection;
  final bool pageSnapping;
  final void Function(EpubChapterViewValue? value)? onChapterChanged;
  final void Function(EpubBook document)? onDocumentLoaded;
  final void Function(Exception? error)? onDocumentError;
  final EpubViewBuilders builders;

  @override
  State<EpubView> createState() => _EpubViewState();
}

class _EpubViewState extends State<EpubView> {
  Exception? _loadingError;
  ItemScrollController? _itemScrollController;
  ItemPositionsListener? _itemPositionListener;
  ScrollController? _scrollController; // Changed to ScrollController for SingleChildScrollView
  List<EpubChapter> _chapters = [];
  List<Paragraph> _paragraphs = [];
  EpubCfiReader? _epubCfiReader;
  EpubChapterViewValue? _currentValue;
  final _chapterIndexes = <int>[];
  List<_PageContent> _pages = [];
  final List<TextHighlight> _highlights = [];
  final Map<int, List<TextHighlight>> _paragraphHighlights = {};

  EpubController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _itemScrollController = ItemScrollController();
    _itemPositionListener = ItemPositionsListener.create();
    _scrollController = ScrollController(); // Initialize ScrollController
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
    _itemPositionListener?.itemPositions.removeListener(_changeListener);
    _controller._detach();
    _scrollController?.dispose();
    super.dispose();
  }

  Future<bool> _init() async {
    if (_controller.isBookLoaded.value) {
      return true;
    }
    _chapters = parseChapters(_controller._document!);
    final parseParagraphsResult = parseParagraphs(
      _chapters,
      _controller._document!.Content,
    );
    _paragraphs = parseParagraphsResult.flatParagraphs;
    _chapterIndexes.addAll(parseParagraphsResult.chapterIndexes);

    _epubCfiReader = EpubCfiReader.parser(
      cfiInput: _controller.epubCfi,
      chapters: _chapters,
      paragraphs: _paragraphs,
    );
    _itemPositionListener?.itemPositions.addListener(_changeListener);
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
    final index = _epubCfiReader?.paragraphIndexByCfifragment;

    if (index == null) {
      return;
    }

    if (widget.scrollDirection == Axis.horizontal && widget.pageSnapping) {
      final pageIndex = findPageContainingParagraph(index);
      _scrollController?.animateTo(
        pageIndex * MediaQuery.of(context).size.width,
        duration: duration,
        curve: curve,
      );
    } else {
      _itemScrollController?.scrollTo(
        index: index,
        duration: duration,
        alignment: alignment,
        curve: curve,
      );
    }
  }

  void _onLinkPressed(String href) {
    if (href.contains('://')) {
      widget.onExternalLinkPressed?.call(href);
      return;
    }

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
      final chapter = paragraph != null ? _chapters[paragraph.chapterIndex] : null;

      if (chapter != null && paragraph != null) {
        final paragraphIndex = _epubCfiReader?.getParagraphIndexByElement(
          paragraph.element,
        );
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

  void addHighlight(
    String text,
    int paragraphIndex, {
    Color? color,
    String? note,
  }) {
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

  List<_PageContent> _calculatePagesImproved(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final availableHeight = screenSize.height - 140;
    final availableWidth = screenSize.width - 40;

    final pages = <_PageContent>[];
    var currentPageParagraphs = <int>[];
    var currentHeight = 0.0;

    for (int i = 0; i < _paragraphs.length; i++) {
      final paragraphText = _paragraphs[i].element.text ?? '';
      final textStyle = (widget.builders as EpubViewBuilders<DefaultBuilderOptions>)
          .options
          .textStyle;
      final textSpan = TextSpan(text: paragraphText, style: textStyle);
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
        maxLines: null,
      );
      textPainter.layout(maxWidth: availableWidth);

      final paragraphHeight = textPainter.size.height + 16.0;

      if (currentHeight + paragraphHeight > availableHeight &&
          currentPageParagraphs.isNotEmpty) {
        pages.add(
          _PageContent(
            paragraphIndexes: List.from(currentPageParagraphs),
            estimatedHeight: currentHeight,
          ),
        );
        currentPageParagraphs = [i];
        currentHeight = paragraphHeight;
      } else {
        currentPageParagraphs.add(i);
        currentHeight += paragraphHeight;
      }
    }

    if (currentPageParagraphs.isNotEmpty) {
      pages.add(
        _PageContent(
          paragraphIndexes: currentPageParagraphs,
          estimatedHeight: currentHeight,
        ),
      );
    }

    return pages;
  }

  Widget _buildPageContent(
    BuildContext context,
    _PageContent pageContent,
    int pageIndex,
    int totalPages,
  ) {
    final screenSize = MediaQuery.of(context).size;

    return AnimatedOpacity(
      opacity: 1.0,
      duration: const Duration(milliseconds: 200),
      child: Container(
        width: screenSize.width,
        height: screenSize.height,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: Colors.grey.withOpacity(0.2),
              width: 1,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              offset: const Offset(3, 0),
              blurRadius: 5,
            ),
          ],
        ),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: pageContent.paragraphIndexes.map((paragraphIndex) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: _buildChapterWithHighlights(
                        context,
                        widget.builders,
                        widget.controller._document!,
                        _chapters,
                        _paragraphs,
                        paragraphIndex,
                        _getChapterIndexBy(positionIndex: paragraphIndex),
                        _getParagraphIndexBy(positionIndex: paragraphIndex),
                        _onLinkPressed,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _getCurrentChapterTitle(pageContent.paragraphIndexes.first),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${pageIndex + 1} / $totalPages',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getCurrentChapterTitle(int paragraphIndex) {
    final chapterIndex = _getChapterIndexBy(positionIndex: paragraphIndex);
    if (chapterIndex >= 0 && chapterIndex < _chapters.length) {
      return _chapters[chapterIndex].Title ?? 'Chapter ${chapterIndex + 1}';
    }
    return '';
  }

  int findPageContainingParagraph(int paragraphIndex) {
    final pages = _calculatePagesImproved(context);
    for (int i = 0; i < pages.length; i++) {
      if (pages[i].paragraphIndexes.contains(paragraphIndex)) {
        return i;
      }
    }
    return 0;
  }

  void jumpToPage(int pageIndex) {
    if (widget.scrollDirection == Axis.horizontal && widget.pageSnapping) {
      _scrollController?.animateTo(
        pageIndex * MediaQuery.of(context).size.width,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _itemScrollController?.jumpTo(index: pageIndex);
    }
  }

  static Widget _chapterDividerBuilder(EpubChapter chapter) => Container(
        height: 56,
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(color: Color(0x24000000)),
        alignment: Alignment.centerLeft,
        child: Text(
          chapter.Title ?? '',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
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
                final url = imageContext.attributes['src']!.replaceAll('../', '');
                final content = Uint8List.fromList(
                  document.Content!.Images![url]!.Content!,
                );
                return Image(image: MemoryImage(content));
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
            final selectedText = paragraphs[index].element.text?.substring(
                      selection.start,
                      selection.end,
                    ) ??
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

  List<TextSpan> _buildHighlightedText(
    String text,
    List<TextHighlight> highlights,
  ) {
    if (highlights.isEmpty) {
      return [TextSpan(text: text)];
    }

    final spans = <TextSpan>[];
    int currentIndex = 0;

    highlights.sort(
      (a, b) => text.indexOf(a.text).compareTo(text.indexOf(b.text)),
    );

    for (final highlight in highlights) {
      final highlightIndex = text.indexOf(highlight.text, currentIndex);

      if (highlightIndex == -1) continue;

      if (highlightIndex > currentIndex) {
        spans.add(TextSpan(text: text.substring(currentIndex, highlightIndex)));
      }

      spans.add(
        TextSpan(
          text: highlight.text,
          style: TextStyle(backgroundColor: highlight.color),
        ),
      );

      currentIndex = highlightIndex + highlight.text.length;
    }

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
      initialScrollIndex: _epubCfiReader?.paragraphIndexByCfiFragment ?? 0,
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

  Widget _buildHorizontalScroll(BuildContext context) {
    _pages = _calculatePagesImproved(context);
    final screenWidth = MediaQuery.of(context).size.width;

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final currentOffset = _scrollController!.offset;
        final currentPage = (currentOffset / screenWidth).round();
        final velocity = details.primaryVelocity ?? 0;
        const velocityThreshold = 300; // Adjusted for sensitivity

        int targetPage = currentPage;
        if (velocity < -velocityThreshold) {
          targetPage = (currentPage + 1).clamp(0, _pages.length - 1);
          HapticFeedback.lightImpact();
        } else if (velocity > velocityThreshold) {
          targetPage = (currentPage - 1).clamp(0, _pages.length - 1);
          HapticFeedback.lightImpact();
        }

        _scrollController!.animateTo(
          targetPage * screenWidth,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );

        if (_pages[targetPage].paragraphIndexes.isNotEmpty) {
          final firstParagraphIndex = _pages[targetPage].paragraphIndexes.first;
          final chapterIndex = _getChapterIndexBy(positionIndex: firstParagraphIndex);
          final paragraphIndex = _getParagraphIndexBy(positionIndex: firstParagraphIndex);
          _currentValue = EpubChapterViewValue(
            chapter: chapterIndex >= 0 ? _chapters[chapterIndex] : null,
            chapterNumber: chapterIndex + 1,
            paragraphNumber: paragraphIndex + 1,
            position: ItemPosition(
              index: firstParagraphIndex,
              itemLeadingEdge: 0,
              itemTrailingEdge: 1,
            ),
          );
          _controller.currentValueListenable.value = _currentValue;
          widget.onChapterChanged?.call(_currentValue);
        }
      },
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        child: Row(
          children: List.generate(_pages.length, (index) {
            return SizedBox(
              width: screenWidth,
              child: _buildPageContent(
                context,
                _pages[index],
                index,
                _pages.length,
              ),
            );
          }),
        ),
      ),
    );
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
    return FutureBuilder<bool>(
      future: _init(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          return widget.builders.builder(
            context,
            widget.builders,
            _controller.loadingState.value,
            _buildLoaded,
            _loadingError,
          );
        }
        return widget.builders.loaderBuilder?.call(context) ?? const SizedBox();
      },
    );
  }
}
