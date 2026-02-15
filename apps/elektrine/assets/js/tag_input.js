export const TagInput = {
  mounted() {
    this.initializeTagInput();
  },

  updated() {
    // If the value was cleared, reinitialize the whole TagInput
    if (this.el.value === '') {
      // Reset the initialization flag
      this.el.dataset.tagInputInitialized = 'false';
      // Restore original textarea if it was replaced
      if (this.tagsContainer && this.tagsContainer.parentElement) {
        this.tagsContainer.parentElement.replaceChild(this.el, this.tagsContainer);
        this.el.type = 'hidden';
        this.el.style.display = '';
      }
      // Reinitialize with empty values
      this.initializeTagInput();
    }
    // Re-initialize when the element updates (e.g., after mode toggle)
    else if (!this.el.dataset.tagInputInitialized || this.el.dataset.tagInputInitialized === 'false') {
      this.initializeTagInput();
    }
  },

  initializeTagInput() {
    const input = this.el;
    const container = input.parentElement;

    // Prevent double initialization
    if (input.dataset.tagInputInitialized === 'true') {
      return;
    }
    input.dataset.tagInputInitialized = 'true';

    // Create tags container that will replace the input - mimic exact input styling
    const tagsContainer = document.createElement('div');
    this.tagsContainer = tagsContainer; // Store reference for later
    // Remove textarea-specific classes and replace with input styling
    let cleanClasses = input.className.replace(/textarea/g, 'input').replace(/min-h-\[.*?\]/g, '');
    // Force exact 40px height with proper padding
    tagsContainer.className = cleanClasses + ' !h-10 flex flex-wrap gap-1 cursor-text items-center !py-1.5 !px-3 overflow-hidden';
    
    // Create visible input for adding new tags
    const tagInput = document.createElement('input');
    tagInput.type = 'text';
    tagInput.className = 'flex-1 min-w-[100px] outline-none bg-transparent border-none focus:border-none focus:outline-none focus:ring-0 text-sm placeholder:text-base-content/50 h-6';
    tagInput.placeholder = input.placeholder || 'Add email...';
    
    // Move any existing value to tags
    const existingEmails = (input.value || '').split(/[,;]\s*/).filter(email => email.trim());
    const tags = [];
    
    existingEmails.forEach(email => {
      if (email && this.isValidEmail(email.trim())) {
        tags.push(email.trim());
      }
    });
    
    // Replace the input with the tags container
    container.replaceChild(tagsContainer, input);
    
    // Add the hidden input back to the container (for form submission)
    input.type = 'hidden';
    input.style.display = 'none';
    container.appendChild(input);
    
    // Render initial tags
    this.renderTags(tags, tagsContainer, tagInput, input);
    
    // Add input to tags container
    tagsContainer.appendChild(tagInput);
    
    // Event listeners
    tagInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ',' || e.key === ';') {
        e.preventDefault();
        this.addTag(tagInput.value, tags, tagsContainer, tagInput, input);
      } else if (e.key === 'Backspace' && tagInput.value === '' && tags.length > 0) {
        // Remove last tag when backspace is pressed on empty input
        tags.pop();
        this.renderTags(tags, tagsContainer, tagInput, input);
      }
    });
    
    tagInput.addEventListener('blur', () => {
      if (tagInput.value.trim()) {
        this.addTag(tagInput.value, tags, tagsContainer, tagInput, input);
      }
    });
    
    // Click on container focuses the input
    tagsContainer.addEventListener('click', (e) => {
      if (e.target === tagsContainer || e.target.classList.contains('tag')) {
        tagInput.focus();
      }
    });
    
    // Handle paste
    tagInput.addEventListener('paste', (e) => {
      e.preventDefault();
      const pastedText = (e.clipboardData || window.clipboardData).getData('text');
      const emails = pastedText.split(/[,;\s]+/).filter(email => email.trim());
      
      emails.forEach(email => {
        this.addTag(email, tags, tagsContainer, tagInput, input);
      });
    });
  },
  
  addTag(value, tags, container, tagInput, hiddenInput) {
    const email = value.trim().replace(/[,;]$/, '').trim();
    
    if (email && this.isValidEmail(email) && !tags.includes(email)) {
      tags.push(email);
      this.renderTags(tags, container, tagInput, hiddenInput);
      tagInput.value = '';
    } else if (email && !this.isValidEmail(email)) {
      // Show error briefly
      tagInput.classList.add('text-error');
      setTimeout(() => {
        tagInput.classList.remove('text-error');
      }, 1000);
    }
  },
  
  renderTags(tags, container, tagInput, hiddenInput) {
    // Clear existing tags (but keep the input)
    const existingTags = container.querySelectorAll('.tag');
    existingTags.forEach(tag => tag.remove());
    
    // Update hidden input
    hiddenInput.value = tags.join(', ');
    
    // Trigger change event for Phoenix
    hiddenInput.dispatchEvent(new Event('change', { bubbles: true }));
    
    // Add tags before the tagInput
    tags.forEach((tag, index) => {
      const tagEl = document.createElement('div');
      tagEl.className = 'tag flex items-center gap-1 px-1.5 py-0.5 bg-base-300 text-base-content rounded text-xs hover:bg-base-300/80 transition-all duration-150';
      
      const textEl = document.createElement('span');
      textEl.textContent = tag;
      
      const removeBtn = document.createElement('button');
      removeBtn.type = 'button';
      removeBtn.className = 'w-3 h-3 rounded-full hover:bg-red-500/30 hover:text-red-600 transition-all duration-150 flex items-center justify-center text-xs leading-none opacity-60 hover:opacity-100';
      removeBtn.innerHTML = '×';
      removeBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        tags.splice(index, 1);
        this.renderTags(tags, container, tagInput, hiddenInput);
      });
      
      tagEl.appendChild(textEl);
      tagEl.appendChild(removeBtn);
      
      // Always append to container - tagInput should be last
      container.appendChild(tagEl);
    });
    
    // Make sure tagInput is always at the end
    if (tagInput.parentNode !== container) {
      container.appendChild(tagInput);
    }
  },
  
  isValidEmail(email) {
    // Basic email validation
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    return emailRegex.test(email);
  }
};