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

  // Setup code truncation for Prism.js highlighting (enhancement, not required)
  setupCodeTruncation();
});

function setupCodeTruncation() {
  const codeElements = document.querySelectorAll('code[data-full-content]');
  
  codeElements.forEach(codeElement => {
    const fullContent = codeElement.getAttribute('data-full-content');
    if (!fullContent) return;
    
    // Update textContent for Prism.js highlighting when JS is enabled
    codeElement.addEventListener('focus', () => {
      // Update textContent for Prism.js highlighting
      if (codeElement.textContent !== fullContent) {
        codeElement.textContent = fullContent;
        codeElement.classList.add('js-enhanced'); // Signal that JS has updated content
        if (typeof Prism !== 'undefined') {
          Prism.highlightElement(codeElement);
        }
      }
    });
    
    codeElement.addEventListener('blur', () => {
      const truncatedContent = codeElement.getAttribute('data-truncated-content') || '';
      if (truncatedContent && codeElement.textContent !== truncatedContent) {
        codeElement.textContent = truncatedContent;
        codeElement.classList.remove('js-enhanced'); // Remove signal when back to truncated
        if (typeof Prism !== 'undefined') {
          Prism.highlightElement(codeElement);
        }
      }
    });
    
    // Also handle hover for non-editable code blocks
    if (!codeElement.hasAttribute('contenteditable')) {
      codeElement.addEventListener('mouseenter', () => {
        if (codeElement.textContent !== fullContent) {
          codeElement.textContent = fullContent;
          codeElement.classList.add('js-enhanced');
          if (typeof Prism !== 'undefined') {
            Prism.highlightElement(codeElement);
          }
        }
      });
      
      codeElement.addEventListener('mouseleave', () => {
        const truncatedContent = codeElement.getAttribute('data-truncated-content') || '';
        if (truncatedContent && codeElement.textContent !== truncatedContent) {
          codeElement.textContent = truncatedContent;
          codeElement.classList.remove('js-enhanced');
          if (typeof Prism !== 'undefined') {
            Prism.highlightElement(codeElement);
          }
        }
      });
    }
  });
}