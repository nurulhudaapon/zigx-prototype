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

  // Setup code truncation toggle for all example blocks
  setupCodeTruncation();
});

function setupCodeTruncation() {
  // Find all code elements with data-full-content attribute
  const codeElements = document.querySelectorAll('code[data-full-content]');
  
  codeElements.forEach(codeElement => {
    const fullContent = codeElement.getAttribute('data-full-content');
    if (!fullContent) return;
    
    // Store truncated content (current displayed content before Prism processing)
    // Get it from the initial textContent before Prism modifies it
    const truncatedContent = codeElement.textContent || codeElement.innerText;
    
    // Store state to track if we're showing full content
    let isShowingFull = false;
    
    // Function to show truncated content
    function showTruncatedContent() {
      if (isShowingFull) {
        codeElement.textContent = truncatedContent;
        isShowingFull = false;
        
        // Re-highlight with Prism.js
        if (typeof Prism !== 'undefined') {
          Prism.highlightElement(codeElement);
        }
      }
    }
    
    // Function to show full content
    function showFullContent() {
      if (!isShowingFull) {
        codeElement.textContent = fullContent;
        isShowingFull = true;
        
        // Re-highlight with Prism.js
        if (typeof Prism !== 'undefined') {
          Prism.highlightElement(codeElement);
        }
      }
    }
    
    // Show full content when code is clicked/focused
    codeElement.addEventListener('focus', showFullContent);
    codeElement.addEventListener('click', showFullContent);
    
    // Show truncated content when code loses focus
    codeElement.addEventListener('blur', showTruncatedContent);
  });
}