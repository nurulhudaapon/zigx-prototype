import * as prettier from "https://unpkg.com/prettier@3.6.2/standalone.mjs";
import * as prettierPluginHtml from "https://unpkg.com/prettier@3.6.2/plugins/html.mjs";

// Find and format HTML code snippets
document.addEventListener("DOMContentLoaded", async () => {
  const htmlCodeElements = document.querySelectorAll('code.language-markup');

  for (const codeElement of htmlCodeElements) {
    const htmlContent = codeElement.textContent || codeElement.innerText;
    
    if (htmlContent.trim()) {
      try {
        const formatted = await prettier.format(htmlContent, {
          parser: "html",
          plugins: [prettierPluginHtml],
          printWidth: 120,
          singleAttributePerLine: false,
          htmlWhitespaceSensitivity: "css",
        });
        
        // Update the code element with formatted content
        codeElement.textContent = formatted;
        
        // Re-highlight with Prism.js if available
        if (typeof Prism !== 'undefined') {
          Prism.highlightElement(codeElement);
        }
      } catch (error) {
        console.error("Error formatting HTML:", error);
      }
    }
  }

  // Setup Prism highlighting for expandable code blocks
  setupCodeHighlighting();
  
  // Setup copy buttons for code blocks
  setupCopyButtons();
});

function setupCodeHighlighting() {
  const codeElements = document.querySelectorAll('code[data-full-content]');
  
  codeElements.forEach(codeElement => {
    const fullContent = codeElement.getAttribute('data-full-content');
    const truncatedContent = codeElement.getAttribute('data-truncated-content') || '';
    
    if (!fullContent) return;
    
    // Handle contenteditable code blocks (ZX code) - use focus/blur
    if (codeElement.hasAttribute('contenteditable')) {
      codeElement.addEventListener('focus', () => {
        codeElement.textContent = fullContent;
        codeElement.setAttribute('data-expanded', 'true');
        if (typeof Prism !== 'undefined') {
          Prism.highlightElement(codeElement);
        }
      });
      
      codeElement.addEventListener('blur', () => {
        codeElement.textContent = truncatedContent;
        codeElement.removeAttribute('data-expanded');
        if (typeof Prism !== 'undefined') {
          Prism.highlightElement(codeElement);
        }
      });
    } else {
      // Handle non-contenteditable code blocks (Zig code) - use hover
      let hoverTimeout = null;
      
      codeElement.addEventListener('mouseenter', () => {
        // Clear any pending timeout
        if (hoverTimeout) {
          clearTimeout(hoverTimeout);
          hoverTimeout = null;
        }
        
        codeElement.textContent = fullContent;
        codeElement.setAttribute('data-expanded', 'true');
        if (typeof Prism !== 'undefined') {
          Prism.highlightElement(codeElement);
        }
      });
      
      codeElement.addEventListener('mouseleave', () => {
        // Delay collapsing by 500ms (CSS handles the visual transition)
        hoverTimeout = setTimeout(() => {
          codeElement.textContent = truncatedContent;
          codeElement.removeAttribute('data-expanded');
          if (typeof Prism !== 'undefined') {
            Prism.highlightElement(codeElement);
          }
          hoverTimeout = null;
        }, 500);
      });
    }
  });
}

function setupCopyButtons() {
  // Find all code blocks (both in example blocks and standalone)
  const codeBlocks = document.querySelectorAll('pre code');
  
  codeBlocks.forEach((codeElement) => {
    const preElement = codeElement.parentElement;
    if (!preElement || preElement.querySelector('.copy-button')) {
      return; // Skip if already has a copy button
    }
    
    // Create copy button
    const copyButton = document.createElement('button');
    copyButton.className = 'copy-button';
    copyButton.setAttribute('aria-label', 'Copy code');
    copyButton.innerHTML = `
      <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
        <path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1.75 0 0 1 9.25 16h-7.5A1.75 1.75 0 0 1 0 14.25v-7.5Z"></path>
        <path d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25v-7.5Zm1.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a.25.25 0 0 0-.25-.25h-7.5Z"></path>
      </svg>
      <span class="copy-text">Copy</span>
    `;
    
    // Add click handler
    copyButton.addEventListener('click', async () => {
      try {
        // Get the code content
        let codeContent = '';
        
        // Check if it's an expandable code block with full content
        const fullContent = codeElement.getAttribute('data-full-content');
        
        // For contenteditable blocks, check if they're currently focused/expanded
        if (codeElement.hasAttribute('contenteditable')) {
          if (codeElement.hasAttribute('data-expanded') || document.activeElement === codeElement) {
            // Use current textContent if expanded (it should have full content)
            codeContent = codeElement.textContent || codeElement.innerText;
          } else if (fullContent) {
            // Use full content from attribute if not expanded
            codeContent = fullContent;
          } else {
            // Fallback to current text content
            codeContent = codeElement.textContent || codeElement.innerText;
          }
        } else if (fullContent) {
          // For non-contenteditable blocks with full content
          if (codeElement.hasAttribute('data-expanded')) {
            // Use current textContent if expanded
            codeContent = codeElement.textContent || codeElement.innerText;
          } else {
            // Use full content from attribute
            codeContent = fullContent;
          }
        } else {
          // Otherwise use the current text content
          codeContent = codeElement.textContent || codeElement.innerText;
        }
        
        // Copy to clipboard
        await navigator.clipboard.writeText(codeContent);
        
        // Update button state
        const copyText = copyButton.querySelector('.copy-text');
        const originalText = copyText.textContent;
        copyText.textContent = 'Copied!';
        copyButton.classList.add('copied');
        
        // Reset after 2 seconds
        setTimeout(() => {
          copyText.textContent = originalText;
          copyButton.classList.remove('copied');
        }, 2000);
      } catch (err) {
        console.error('Failed to copy code:', err);
        // Fallback for older browsers
        const textArea = document.createElement('textarea');
        textArea.value = codeElement.textContent || codeElement.innerText;
        textArea.style.position = 'fixed';
        textArea.style.opacity = '0';
        document.body.appendChild(textArea);
        textArea.select();
        try {
          document.execCommand('copy');
          const copyText = copyButton.querySelector('.copy-text');
          const originalText = copyText.textContent;
          copyText.textContent = 'Copied!';
          copyButton.classList.add('copied');
          setTimeout(() => {
            copyText.textContent = originalText;
            copyButton.classList.remove('copied');
          }, 2000);
        } catch (fallbackErr) {
          console.error('Fallback copy failed:', fallbackErr);
        }
        document.body.removeChild(textArea);
      }
    });
    
    // Append button to pre element
    preElement.appendChild(copyButton);
  });
}