import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:collection/collection.dart' show IterableExtension;
import 'package:epub_view/src/data/epub_cfi_reader.dart';
import 'package:epub_view/src/data/epub_parser.dart';
import 'package:epub_view/src/data/models/chapter.dart';
import 'package:epub_view/src/data/models/chapter_view_value.dart';
import 'package:epub_view/src/data/models/paragraph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

part '../epub_controller.dart';
part '../helpers/epub_view_builders.dart';

const _minTrailingEdge = 0.55;
const _minLeadingEdge = -0.05;

typedef ExternalLinkPressed = void Function(String href);
typedef TextSelectedCallback = void Function(String selectedText, int paragraphIndex);

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
  List<EpubChapter> _chapters = [];
  List<Paragraph> _paragraphs = [];
  EpubCfiReader? _epubCfiReader;
  EpubChapterViewValue? _currentValue;
  final _chapterIndexes = <int>[];
  final List<TextHighlight> _highlights = [];
  final Map<int, List<TextHighlight>> _paragraphHighlights = {};
  final Map<int, double> _paragraphHeights = {};
  final List<int> _pageBreaks = [];
  double _pageHeight = 0;
  final PageController _pageController = PageController();
  int _currentPage = 0;

  EpubController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _itemScrollController = ItemScrollController();
    _itemPositionListener = ItemPositionsListener.create();
    _controller._attach(this);
    _controller.loadingState.addListener(_handleLoadingStateChange);
  }

  void _handleLoadingStateChange() {
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

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _itemPositionListener?.itemPositions.removeListener(_changeListener);
    _controller._detach();
    _pageController.dispose();
    super.dispose();
  }

  Future<bool> _init() async {
    if (_controller.isBookLoaded.value) return true;
    
    _chapters = parseChapters(_controller._document!);
    final parseParagraphsResult = parseParagraphs(_chapters, _controller._document!.Content!);
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
    if (_paragraphs.isEmpty || _itemPositionListener?.itemPositions.value.isEmpty ?? true) return;
    
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

  Future<void> _calculatePageBreaks(BoxConstraints constraints) async {
    if (_paragraphs.isEmpty) return;

    _pageHeight = constraints.maxHeight;
    _paragraphHeights.clear();
    _pageBreaks.clear();

    double currentHeight = 0;
    int currentPageStart = 0;
    const double verticalPadding = 40;

    for (int i = 0; i < _paragraphs.length; i++) {
      final height = await _estimateParagraphHeight(i, constraints.maxWidth);
      _paragraphHeights[i] = height;

      if (currentHeight + height > _pageHeight - verticalPadding) {
        _pageBreaks.add(currentPageStart);
        currentPageStart = i;
        currentHeight = height;
      } else {
        currentHeight += height;
      }
    }

    if (currentPageStart < _paragraphs.length) {
      _pageBreaks.add(currentPageStart);
    }

    _pageBreaks.add(_paragraphs.length);
    
    if (mounted) setState(() {});
  }

  Future<double> _estimateParagraphHeight(int index, double maxWidth) async {
    final paragraph = _paragraphs[index];
    final defaultBuilder = widget.builders as EpubViewBuilders<DefaultBuilderOptions>;
    final style = defaultBuilder.options.textStyle;
    final text = paragraph.element.text ?? '';
    final textSpan = TextSpan(text: text, style: style);

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: maxWidth - 40);

    return textPainter.height + 16;
  }

  int _getPageForParagraph(int paragraphIndex) {
    for (int i = 0; i < _pageBreaks.length - 1; i++) {
      if (paragraphIndex >= _pageBreaks[i] && paragraphIndex < _pageBreaks[i + 1]) {
        return i;
      }
    }
    return 0;
  }

  Widget _buildHorizontalPagination(BuildContext context, BoxConstraints constraints) {
    if (_pageBreaks.isEmpty) {
      return Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.horizontal,
            itemCount: _pageBreaks.length - 1,
            onPageChanged: (index) {
              setState(() {
                _currentPage = index;
              });
            },
            itemBuilder: (context, pageIndex) {
              final start = _pageBreaks[pageIndex];
              final end = _pageBreaks[pageIndex + 1];
              
              return Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: Colors.grey.shade300)),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: List.generate(end - start, (index) {
                      final paragraphIndex = start + index;
                      return _buildParagraphWithHighlights(paragraphIndex);
                    }),
                  ),
                ),
              );
            },
          ),
        ),
        _buildPageIndicator(),
      ],
    );
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
        return _buildParagraphWithHighlights(index);
      },
    );
  }

  Widget _buildParagraphWithHighlights(int paragraphIndex) {
    final paragraph = _paragraphs[paragraphIndex];
    final defaultBuilder = widget.builders as EpubViewBuilders<DefaultBuilderOptions>;
    final options = defaultBuilder.options;
    final highlights = _paragraphHighlights[paragraphIndex] ?? [];

    return Padding(
      padding: options.paragraphPadding as EdgeInsets? ?? EdgeInsets.all(8),
      child: SelectableText.rich(
        TextSpan(
          children: _buildHighlightedText(paragraph.element.text ?? '', highlights),
        ),
        style: options.textStyle,
        onSelectionChanged: (selection, cause) {
          if (selection.isCollapsed) return;
          final text = paragraph.element.text ?? '';
          final selectedText = text.substring(selection.start, selection.end);
          if (selectedText.isNotEmpty) {
            widget.onTextSelected?.call(selectedText, paragraphIndex);
          }
        },
      ),
    );
  }

  List<TextSpan> _buildHighlightedText(String text, List<TextHighlight> highlights) {
    if (highlights.isEmpty) return [TextSpan(text: text)];

    final spans = <TextSpan>[];
    int currentIndex = 0;

    highlights.sort((a, b) => text.indexOf(a.text).compareTo(text.indexOf(b.text)));

    for (final highlight in highlights) {
      final highlightIndex = text.indexOf(highlight.text, currentIndex);
      if (highlightIndex == -1) continue;

      if (highlightIndex > currentIndex) {
        spans.add(TextSpan(text: text.substring(currentIndex, highlightIndex)));
      }

      spans.add(TextSpan(
        text: highlight.text,
        style: TextStyle(backgroundColor: highlight.color),
      ));

      currentIndex = highlightIndex + highlight.text.length;
    }

    if (currentIndex < text.length) {
      spans.add(TextSpan(text: text.substring(currentIndex)));
    }

    return spans;
  }

  Widget _buildPageIndicator() {
    if (_pageBreaks.length <= 2) return SizedBox.shrink();
    
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Page ${_currentPage + 1} of ${_pageBreaks.length - 1}',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

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
            if (posIndex < chapterIndex) return true;
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

    if (index == -1) return posIndex;

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

  @override
  Widget build(BuildContext context) {
    return widget.builders.builder(
      context,
      widget.builders,
      _controller.loadingState.value,
      (context) => LayoutBuilder(
        builder: (context, constraints) {
          if (_controller.isBookLoaded.value && _pageBreaks.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _calculatePageBreaks(constraints);
            });
          }

          if (widget.scrollDirection == Axis.horizontal && widget.pageSnapping) {
            return _buildHorizontalPagination(context, constraints);
          } else {
            return _buildVerticalScroll(context);
          }
        },
      ),
      _loadingError,
    );
  }
}
