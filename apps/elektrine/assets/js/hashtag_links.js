// Convert hashtags to clickable links without affecting spacing
export function initHashtagLinks() {
  if (window.__elektrineHashtagObserver) {
    window.__elektrineHashtagObserver.disconnect();
    window.__elektrineHashtagObserver = null;
  }

  // Function to convert hashtags in text content
  function makeHashtagsClickable() {
    // Find all post content elements
    const postContents = document.querySelectorAll('[data-hashtag-content]');

    postContents.forEach(element => {
      if (element.dataset.hashtagProcessed) return; // Skip if already processed

      const originalText = element.textContent;
      const hashtagRegex = /#(\w+)/g;
      const fragment = document.createDocumentFragment();
      let lastIndex = 0;
      let foundHashtag = false;

      originalText.replace(hashtagRegex, (match, hashtag, offset) => {
        foundHashtag = true;
        fragment.appendChild(document.createTextNode(originalText.slice(lastIndex, offset)));

        const normalizedHashtag = hashtag.toLowerCase();
        const link = document.createElement("a");
        link.href = `/hashtag/${encodeURIComponent(normalizedHashtag)}`;
        link.className = "text-primary hover:underline font-medium";
        link.textContent = match;
        fragment.appendChild(link);
        lastIndex = offset + match.length;

        return match;
      });

      if (foundHashtag) {
        fragment.appendChild(document.createTextNode(originalText.slice(lastIndex)));
        element.replaceChildren(fragment);
        element.dataset.hashtagProcessed = 'true';
      }
    });
  }

  // Process hashtags on page load
  makeHashtagsClickable();

  // Process hashtags when new content is added (LiveView updates)
  const observer = new MutationObserver((mutations) => {
    let shouldProcess = false;
    mutations.forEach((mutation) => {
      if (mutation.type === 'childList' && mutation.addedNodes.length > 0) {
        shouldProcess = true;
      }
    });

    if (shouldProcess) {
      setTimeout(makeHashtagsClickable, 10); // Small delay to ensure DOM is ready
    }
  });

  // Observe the main timeline for changes
  const timelineContainer = document.querySelector('[data-timeline-container]');
  if (timelineContainer) {
    observer.observe(timelineContainer, {
      childList: true,
      subtree: true
    });
    window.__elektrineHashtagObserver = observer;
  }
}

// Auto-initialize when DOM is ready
document.addEventListener('DOMContentLoaded', initHashtagLinks);

// Also initialize on LiveView page loads
document.addEventListener('phx:page-loading-stop', initHashtagLinks);
