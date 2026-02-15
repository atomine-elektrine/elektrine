// Convert hashtags to clickable links without affecting spacing
export function initHashtagLinks() {
  // Function to convert hashtags in text content
  function makeHashtagsClickable() {
    // Find all post content elements
    const postContents = document.querySelectorAll('[data-hashtag-content]');

    postContents.forEach(element => {
      if (element.dataset.hashtagProcessed) return; // Skip if already processed

      const originalText = element.textContent;
      const hashtagRegex = /#(\w+)/g;

      // Replace hashtags with clickable links
      const htmlContent = originalText.replace(hashtagRegex, (match, hashtag) => {
        const normalizedHashtag = hashtag.toLowerCase();
        return `<a href="/hashtag/${normalizedHashtag}" class="text-primary hover:underline font-medium">${match}</a>`;
      });

      // Only update if we found hashtags
      if (htmlContent !== originalText) {
        element.innerHTML = htmlContent;
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
  }
}

// Auto-initialize when DOM is ready
document.addEventListener('DOMContentLoaded', initHashtagLinks);

// Also initialize on LiveView page loads
document.addEventListener('phx:page-loading-stop', initHashtagLinks);