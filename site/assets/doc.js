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