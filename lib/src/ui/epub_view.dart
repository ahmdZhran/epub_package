// Replace the existing _buildHorizontalScroll method and add these new methods

class _PageContent {
  final List<int> paragraphIndexes;
  final double estimatedHeight;
  
  _PageContent({required this.paragraphIndexes, required this.estimatedHeight});
}

// Better page calculation method
List<_PageContent> _calculatePagesImproved(BuildContext context) {
  final screenSize = MediaQuery.of(context).size;
  final availableHeight = screenSize.height - 140; // Account for padding, safe area, page indicator
  final availableWidth = screenSize.width - 40; // Account for horizontal padding
  
  final pages = <_PageContent>[];
  var currentPageParagraphs = <int>[];
  var currentHeight = 0.0;
  
  for (int i = 0; i < _paragraphs.length; i++) {
    final paragraphText = _paragraphs[i].element.text ?? '';
    
    // More accurate height estimation
    final textStyle = (widget.builders as EpubViewBuilders<DefaultBuilderOptions>).options.textStyle;
    final textSpan = TextSpan(text: paragraphText, style: textStyle);
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
      maxLines: null,
    );
    textPainter.layout(maxWidth: availableWidth);
    
    final paragraphHeight = textPainter.size.height + 16.0; // Add some padding
    
    // Check if adding this paragraph would exceed page height
    if (currentHeight + paragraphHeight > availableHeight && currentPageParagraphs.isNotEmpty) {
      pages.add(_PageContent(
        paragraphIndexes: List.from(currentPageParagraphs),
        estimatedHeight: currentHeight,
      ));
      currentPageParagraphs = [i];
      currentHeight = paragraphHeight;
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

// Build a single page with proper content fitting
Widget _buildPageContent(BuildContext context, _PageContent pageContent, int pageIndex, int totalPages) {
  final screenSize = MediaQuery.of(context).size;
  
  return Container(
    width: screenSize.width,
    height: screenSize.height,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
    child: Column(
      children: [
        // Main content area
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
        
        // Page indicator at bottom
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Chapter info (optional)
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
              
              // Page number
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

// Get current chapter title for page indicator
String _getCurrentChapterTitle(int paragraphIndex) {
  final chapterIndex = _getChapterIndexBy(positionIndex: paragraphIndex);
  if (chapterIndex >= 0 && chapterIndex < _chapters.length) {
    return _chapters[chapterIndex].Title ?? 'Chapter ${chapterIndex + 1}';
  }
  return '';
}

// Improved horizontal scroll with better page experience
Widget _buildHorizontalScroll(BuildContext context) {
  if (widget.pageSnapping) {
    final pages = _calculatePagesImproved(context);
    
    return PageView.builder(
      physics: const PageScrollPhysics(),
      scrollDirection: Axis.horizontal,
      itemCount: pages.length,
      onPageChanged: (int pageIndex) {
        // Update current position based on page change
        if (pages[pageIndex].paragraphIndexes.isNotEmpty) {
          final firstParagraphIndex = pages[pageIndex].paragraphIndexes.first;
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
      itemBuilder: (BuildContext context, int pageIndex) {
        return _buildPageContent(context, pages[pageIndex], pageIndex, pages.length);
      },
    );
  } else {
    // Fallback to scroll-based approach but with better page-like items
    final pages = _calculatePagesImproved(context);
    
    return ScrollablePositionedList.builder(
      shrinkWrap: widget.shrinkWrap,
      scrollDirection: Axis.horizontal,
      initialScrollIndex: 0,
      itemCount: pages.length,
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionListener,
      itemBuilder: (BuildContext context, int pageIndex) {
        return _buildPageContent(context, pages[pageIndex], pageIndex, pages.length);
      },
    );
  }
}

// Additional method to jump to specific page
void jumpToPage(int pageIndex) {
  if (widget.pageSnapping) {
    // For PageView, we need to use a PageController
    // You might want to replace PageView.builder with a PageView that uses a controller
  } else {
    _itemScrollController?.jumpTo(index: pageIndex);
  }
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
