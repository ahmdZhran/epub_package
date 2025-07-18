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
import 'package:shared_preferences/shared_preferences.dart';

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
    this.bookId, // This is crucial for API books
    this.bookUrl, // Add book URL for additional identification
    this.bookTitle,
    this.onDocumentError,
    this.onTextSelected, // New callback for text selection
    this.builders = const EpubViewBuilders<DefaultBuilderOptions>(
      options: DefaultBuilderOptions(),
    ),
    this.shrinkWrap = false,
    this.scrollDirection = Axis.vertical, // New parameter for scroll direction
    this.pageSnapping = false,
    Key? key,
  }) : super(key: key);

  final EpubController controller;
  final ExternalLinkPressed? onExternalLinkPressed;
  final TextSelectedCallback? onTextSelected;
  final bool shrinkWrap;
  final Axis scrollDirection; // New: scroll direction
  final bool pageSnapping;
  final void Function(EpubChapterViewValue? value)? onChapterChanged;
  final String? bookId;
  final String? bookUrl;
  final String? bookTitle;

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
  PageController? _pageController;
  List<EpubChapter> _chapters = [];
  List<Paragraph> _paragraphs = [];
  EpubCfiReader? _epubCfiReader;
  EpubChapterViewValue? _currentValue;
  final _chapterIndexes = <int>[];
  List<_PageContent> _pages = [];

  final List<TextHighlight> _highlights = [];
  final Map<int, List<TextHighlight>> _paragraphHighlights = {};

  EpubController get _controller => widget.controller;
  late List<Widget> _cachedPages;

  @override
  void initState() {
    super.initState();
    _itemScrollController = ItemScrollController();
    _itemPositionListener = ItemPositionsListener.create();
    _pageController = PageController(initialPage: 0);
    _currentPageIndex = 0;

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pages = _calculatePagesImproved(context);
      _cachedPages = _pages.asMap().entries.map((entry) {
        final index = entry.key;
        final page = entry.value;

        return KeyedSubtree(
          key: ValueKey(index),
          child: _buildPageContent(
            context,
            page,
            index,
            _pages.length,
          ),
        );
      }).toList();

      if (mounted) {
        setState(() {});
      }
    });
  }

  String _getBookIdentifier() {
    // Priority order: bookId > bookUrl hash > bookTitle hash
    if (widget.bookId != null && widget.bookId!.isNotEmpty) {
      return widget.bookId!;
    }

    if (widget.bookUrl != null && widget.bookUrl!.isNotEmpty) {
      // Create a hash from URL for consistent identification
      return 'url_${widget.bookUrl.hashCode.abs()}';
    }

    if (widget.bookTitle != null && widget.bookTitle!.isNotEmpty) {
      // Create a hash from title as last resort
      return 'title_${widget.bookTitle.hashCode.abs()}';
    }

    // If no identifier available, use a default (won't save progress)
    return 'unknown_book';
  }

  Future<void> _saveLastPage(int pageIndex) async {
    final bookIdentifier = _getBookIdentifier();
    if (bookIdentifier == 'unknown_book') {
      print(
          'Warning: No book identifier provided. Progress will not be saved.');
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_page_$bookIdentifier', pageIndex);

      // Also save additional metadata for API books
      await prefs.setString('book_url_$bookIdentifier', widget.bookUrl ?? '');
      await prefs.setString(
          'book_title_$bookIdentifier', widget.bookTitle ?? '');
      await prefs.setInt('last_saved_timestamp_$bookIdentifier',
          DateTime.now().millisecondsSinceEpoch);

      print('Saved progress for book: $bookIdentifier, page: $pageIndex');
    } catch (e) {
      print('Error saving progress: $e');
    }
  }

  Future<int> _loadLastPage() async {
    final bookIdentifier = _getBookIdentifier();
    if (bookIdentifier == 'unknown_book') return 0;

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPage = prefs.getInt('last_page_$bookIdentifier') ?? 0;

      // Optional: Check if saved data is not too old (e.g., 30 days)
      final timestamp = prefs.getInt('last_saved_timestamp_$bookIdentifier');
      if (timestamp != null) {
        final savedDate = DateTime.fromMillisecondsSinceEpoch(timestamp);
        final daysDifference = DateTime.now().difference(savedDate).inDays;

        if (daysDifference > 30) {
          print(
              'Saved progress is older than 30 days, starting from beginning');
          return 0;
        }
      }

      print('Loaded progress for book: $bookIdentifier, page: $savedPage');
      return savedPage;
    } catch (e) {
      print('Error loading progress: $e');
      return 0;
    }
  }

  Future<List<Map<String, dynamic>>> getSavedBooks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final savedBooks = <Map<String, dynamic>>[];

      for (final key in keys) {
        if (key.startsWith('last_page_')) {
          final bookId = key.substring('last_page_'.length);
          final lastPage = prefs.getInt(key) ?? 0;
          final bookUrl = prefs.getString('book_url_$bookId') ?? '';
          final bookTitle = prefs.getString('book_title_$bookId') ?? '';
          final timestamp = prefs.getInt('last_saved_timestamp_$bookId');

          savedBooks.add({
            'bookId': bookId,
            'lastPage': lastPage,
            'bookUrl': bookUrl,
            'bookTitle': bookTitle,
            'lastSaved': timestamp != null
                ? DateTime.fromMillisecondsSinceEpoch(timestamp)
                : null,
          });
        }
      }

      return savedBooks;
    } catch (e) {
      print('Error getting saved books: $e');
      return [];
    }
  }

  Future<void> clearOldSavedData({int olderThanDays = 90}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final cutoffDate = DateTime.now().subtract(Duration(days: olderThanDays));

      for (final key in keys) {
        if (key.startsWith('last_saved_timestamp_')) {
          final timestamp = prefs.getInt(key);
          if (timestamp != null) {
            final savedDate = DateTime.fromMillisecondsSinceEpoch(timestamp);
            if (savedDate.isBefore(cutoffDate)) {
              final bookId = key.substring('last_saved_timestamp_'.length);
              await prefs.remove('last_page_$bookId');
              await prefs.remove('book_url_$bookId');
              await prefs.remove('book_title_$bookId');
              await prefs.remove('last_saved_timestamp_$bookId');
              print('Cleared old data for book: $bookId');
            }
          }
        }
      }
    } catch (e) {
      print('Error clearing old data: $e');
    }
  }

  @override
  void dispose() {
    _itemPositionListener?.itemPositions.removeListener(_changeListener);
    _controller._detach();
    _pageController?.dispose();
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
    final index = _epubCfiReader?.paragraphIndexByCfiFragment;

    if (index == null) {
      return;
    }

    if (widget.scrollDirection == Axis.horizontal && widget.pageSnapping) {
      // For horizontal pagination, find the page containing this paragraph
      final pageIndex = findPageContainingParagraph(index);
      _pageController?.animateToPage(
        pageIndex,
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

  // New: Add highlight functionality
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
    final safeArea = MediaQuery.of(context).padding;

    // More precise available space calculation
    final availableHeight = screenSize.height -
        safeArea.top -
        safeArea.bottom -
        100; // Reduced margin for better space utilization

    final availableWidth = screenSize.width - 40;

    final pages = <_PageContent>[];
    var currentPageParagraphs = <int>[];
    var currentHeight = 0.0;

    final textStyle =
        (widget.builders as EpubViewBuilders<DefaultBuilderOptions>)
            .options
            .textStyle;

    for (int i = 0; i < _paragraphs.length; i++) {
      final paragraphText = _paragraphs[i].element.text ?? '';

      // Skip completely empty paragraphs but keep small spacing
      if (paragraphText.trim().isEmpty) {
        if (currentPageParagraphs.isNotEmpty) {
          currentPageParagraphs.add(i);
          currentHeight += 8.0; // Small space for empty paragraphs
        }
        continue;
      }

      final paragraphHeight =
          _calculateParagraphHeight(paragraphText, textStyle, availableWidth);

      // Use 95% of available height for better space utilization
      if (currentHeight + paragraphHeight > availableHeight * 0.95) {
        // Only create new page if current page has content
        if (currentPageParagraphs.isNotEmpty) {
          pages.add(_PageContent(
            paragraphIndexes: List.from(currentPageParagraphs),
            estimatedHeight: currentHeight,
          ));
          currentPageParagraphs = [i];
          currentHeight = paragraphHeight;
        } else {
          // If single paragraph is too long, split it
          final splitParagraphs = _splitLongParagraph(
              i, paragraphText, textStyle, availableWidth, availableHeight);

          for (final splitInfo in splitParagraphs) {
            pages.add(_PageContent(
              paragraphIndexes: [splitInfo.paragraphIndex],
              estimatedHeight: splitInfo.height,
            ));
          }
        }
      } else {
        currentPageParagraphs.add(i);
        currentHeight += paragraphHeight;
      }
    }

    // Add the last page if it has content
    if (currentPageParagraphs.isNotEmpty) {
      pages.add(_PageContent(
        paragraphIndexes: currentPageParagraphs,
        estimatedHeight: currentHeight,
      ));
    }

    return pages;
  }

  bool _isArabicText(String text) {
    final arabicRegex = RegExp(
        r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]');
    return arabicRegex.hasMatch(text);
  }

  TextDirection _getTextDirection(String text) {
    return _isArabicText(text) ? TextDirection.rtl : TextDirection.ltr;
  }

  double _calculateParagraphHeight(
      String text, TextStyle textStyle, double maxWidth) {
    if (text.trim().isEmpty) return 8.0;

    final textSpan = TextSpan(text: text, style: textStyle);
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: _getTextDirection(text),
      maxLines: null,
    );
    textPainter.layout(maxWidth: maxWidth);

    // Consistent spacing between paragraphs
    return textPainter.size.height + 12.0;
  }

  List<_ParagraphSplit> _splitLongParagraph(
    int originalIndex,
    String text,
    TextStyle textStyle,
    double maxWidth,
    double maxHeight,
  ) {
    final splits = <_ParagraphSplit>[];
    final isArabic = _isArabicText(text);

    final sentences = isArabic
        ? text.split(RegExp(r'[.!?؟۔]\s+'))
        : text.split(RegExp(r'[.!?]+\s+'));

    var currentText = '';
    var currentHeight = 0.0;

    for (int i = 0; i < sentences.length; i++) {
      final sentence = sentences[i].trim();
      if (sentence.isEmpty) continue;

      final separator = isArabic ? '؟ ' : '. ';
      final testText =
          currentText.isEmpty ? sentence : '$currentText$separator$sentence';
      final testHeight =
          _calculateParagraphHeight(testText, textStyle, maxWidth);

      if (testHeight > maxHeight * 0.95 && currentText.isNotEmpty) {
        splits.add(_ParagraphSplit(
          paragraphIndex: originalIndex,
          text: currentText,
          height: currentHeight,
        ));

        currentText = sentence;
        currentHeight =
            _calculateParagraphHeight(currentText, textStyle, maxWidth);
      } else {
        currentText = testText;
        currentHeight = testHeight;
      }
    }

    if (currentText.isNotEmpty) {
      splits.add(_ParagraphSplit(
        paragraphIndex: originalIndex,
        text: currentText,
        height: currentHeight,
      ));
    }

    return splits;
  }

  Widget _buildPageContent(
    BuildContext context,
    _PageContent pageContent,
    int pageIndex,
    int totalPages,
  ) {
    final screenSize = MediaQuery.of(context).size;
    final safeArea = MediaQuery.of(context).padding;

    return Container(
      width: screenSize.width,
      height: screenSize.height,
      color: Colors.white, // Set background color
      child: Column(
        children: [
          // Main content area with better space utilization
          Expanded(
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: safeArea.top + 10,
                bottom: 10,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  // Content area that fills available space
                  Expanded(
                    child: SingleChildScrollView(
                      physics:
                          const NeverScrollableScrollPhysics(), // Disable scrolling since content should fit
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children:
                            pageContent.paragraphIndexes.map((paragraphIndex) {
                          return Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 8.0),
                            child: _buildParagraphContent(
                              context,
                              paragraphIndex,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              border: Border(top: BorderSide(color: Colors.grey[300]!)),
            ),
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
    );
  }

  Widget _buildParagraphContent(BuildContext context, int paragraphIndex) {
    if (paragraphIndex >= _paragraphs.length) return Container();

    final paragraph = _paragraphs[paragraphIndex];
    final text = paragraph.element.text ?? '';

    // Handle empty paragraphs
    if (text.trim().isEmpty) {
      return const SizedBox(height: 8);
    }

    final chapterIndex = _getChapterIndexBy(positionIndex: paragraphIndex);
    final relParagraphIndex =
        _getParagraphIndexBy(positionIndex: paragraphIndex);

    // Get text style
    final defaultBuilder =
        widget.builders as EpubViewBuilders<DefaultBuilderOptions>;
    final options = defaultBuilder.options;

    // Get highlights for this paragraph
    final highlights = _paragraphHighlights[paragraphIndex] ?? [];

    // Detect text direction and alignment
    final isArabic = _isArabicText(text);
    final textDirection = _getTextDirection(text);
    final textAlign = isArabic ? TextAlign.right : TextAlign.left;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Chapter divider if needed
        if (chapterIndex >= 0 && relParagraphIndex == 0)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _chapters[chapterIndex].Title ?? 'Chapter ${chapterIndex + 1}',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
              textDirection:
                  _getTextDirection(_chapters[chapterIndex].Title ?? ''),
              textAlign: _isArabicText(_chapters[chapterIndex].Title ?? '')
                  ? TextAlign.right
                  : TextAlign.left,
            ),
          ),

        // Paragraph content with proper alignment and direction
        SizedBox(
          width: double.infinity,
          child: Directionality(
            textDirection: textDirection,
            child: SelectableText.rich(
              TextSpan(
                children: _buildHighlightedText(text, highlights),
              ),
              onSelectionChanged: (selection, cause) {
                if (selection.isCollapsed) return;
                final selectedText = text.substring(
                  selection.start,
                  selection.end,
                );
                if (selectedText.isNotEmpty) {
                  _onTextSelected(selectedText, paragraphIndex);
                }
              },
              style: options.textStyle.copyWith(
                height: 1.5, // Better line spacing
                letterSpacing:
                    isArabic ? 0.0 : 0.3, // No letter spacing for Arabic
              ),
              textAlign: textAlign,
              textDirection: textDirection,
            ),
          ),
        ),
      ],
    );
  }

  // Get current chapter title for page indicator
  String _getCurrentChapterTitle(int paragraphIndex) {
    final chapterIndex = _getChapterIndexBy(positionIndex: paragraphIndex);
    if (chapterIndex >= 0 && chapterIndex < _chapters.length) {
      return _chapters[chapterIndex].Title ?? 'Chapter ${chapterIndex + 1}';
    }
    return '';
  }

  // Method to find page containing specific paragraph
  int findPageContainingParagraph(int paragraphIndex) {
    final pages = _calculatePagesImproved(context);
    for (int i = 0; i < pages.length; i++) {
      if (pages[i].paragraphIndexes.contains(paragraphIndex)) {
        return i;
      }
    }
    return 0;
  }

  // Method to jump to specific page
  void jumpToPage(int pageIndex) {
    if (widget.pageSnapping && _pageController != null) {
      _pageController!.animateToPage(
        pageIndex,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _itemScrollController?.jumpTo(index: pageIndex);
    }
  }

// Also add a method to save current page
  void saveCurrentPage() {
    if (_currentPageIndex >= 0 && widget.pageSnapping) {
      _saveLastPage(_currentPageIndex);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      saveCurrentPage();
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
                final url = imageContext.attributes['src']!.replaceAll(
                  '../',
                  '',
                );
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
            final selectedText = paragraphs[index].element.text.substring(
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

  // New: Build highlighted text spans
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

  int _currentPageIndex = 0;
  void _onPageChanged(int pageIndex) {
    _currentPageIndex = pageIndex;
    _saveLastPage(pageIndex);
    if (_pages[pageIndex].paragraphIndexes.isNotEmpty) {
      final firstParagraphIndex = _pages[pageIndex].paragraphIndexes.first;
      final chapterIndex =
          _getChapterIndexBy(positionIndex: firstParagraphIndex);
      final paragraphIndex =
          _getParagraphIndexBy(positionIndex: firstParagraphIndex);

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
  }

  Widget _buildHorizontalScroll(BuildContext context) {
    _pages = _calculatePagesImproved(context);
    final isRTL = Directionality.of(context) == TextDirection.rtl;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            itemCount: _pages.length,
            physics: const NeverScrollableScrollPhysics(),
            itemBuilder: (context, index) {
              return Material(
                elevation: 2,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: _buildPageContent(
                  context,
                  _pages[index],
                  index,
                  _pages.length,
                ),
              );
            },
          ),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    final targetPage =
                        isRTL ? _currentPageIndex - 1 : _currentPageIndex + 1;
                    if (targetPage >= 0 && targetPage < _pages.length) {
                      _goToPage(targetPage);
                    }
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),
              Expanded(
                flex: 4, // 40% of width
                child: Container(color: Colors.transparent),
              ),
              Expanded(
                flex: 3,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    final targetPage =
                        isRTL ? _currentPageIndex + 1 : _currentPageIndex - 1;
                    if (targetPage >= 0 && targetPage < _pages.length) {
                      _goToPage(targetPage);
                    }
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _goToPage(int index) {
    _pageController?.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
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

class _ParagraphSplit {
  final int paragraphIndex;
  final String text;
  final double height;

  _ParagraphSplit({
    required this.paragraphIndex,
    required this.text,
    required this.height,
  });
}
