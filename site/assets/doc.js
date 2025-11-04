import * as prettier from "https://unpkg.com/prettier@3.6.2/standalone.mjs";
import * as prettierPluginHtml from "https://unpkg.com/prettier@3.6.2/plugins/html.mjs";

// Find and format HTML code snippets
document.addEventListener("DOMContentLoaded", async () => {
  // Ensure preview tab is active on page load for all example blocks
  const previewRadios = document.querySelectorAll('input.tab-radio[type="radio"]');
  previewRadios.forEach(radio => {
    if (radio.id.includes('-preview') && !radio.checked) {
      radio.checked = true;
    }
  });

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
  
  // Ensure preview tabs are still active after formatting
  previewRadios.forEach(radio => {
    if (radio.id.includes('-preview') && !radio.checked) {
      radio.checked = true;
    }
  });

  // Truncate ZX and Zig code sections for all example blocks
  setupCodeTruncation();
});

function setupCodeTruncation() {
  // Find all example blocks
  const codeExamples = document.querySelectorAll('.code-example');
  
  codeExamples.forEach(exampleBlock => {
    // Find ZX code element in this block
    const zxCodeElement = exampleBlock.querySelector('code.language-jsx');
    if (!zxCodeElement) return;
    
    // Find the corresponding Zig code element
    // Extract the example ID from the ZX code element ID (e.g., "zx-code-if" -> "if")
    const zxId = zxCodeElement.id;
    const exampleId = zxId.replace('zx-code-', '');
    const zigCodeElement = exampleBlock.querySelector(`#tab-zig-${exampleId} code.language-zig`);
    
    setupExampleBlockCodeTruncation(zxCodeElement, zigCodeElement);
  });
}

function setupExampleBlockCodeTruncation(zxCodeElement, zigCodeElement) {
  if (!zxCodeElement) return;
  
  // Store full ZX content (get raw text before any processing)
  const fullZxContent = zxCodeElement.textContent || zxCodeElement.innerText;
  
  // Function to remove common leading indentation while preserving relative indentation
  function removeCommonIndentation(content) {
    // Split into lines first to preserve structure
    const lines = content.split('\n');
    
    // Find minimum indentation from non-empty lines (excluding leading/trailing empty lines)
    let minIndent = Infinity;
    let firstNonEmptyIndex = -1;
    let lastNonEmptyIndex = -1;
    
    // Find first and last non-empty lines
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].trim().length > 0) {
        if (firstNonEmptyIndex === -1) {
          firstNonEmptyIndex = i;
        }
        lastNonEmptyIndex = i;
      }
    }
    
    // If no non-empty lines, return original content
    if (firstNonEmptyIndex === -1) {
      return content.trim();
    }
    
    // Find minimum indentation among non-empty lines
    for (let i = firstNonEmptyIndex; i <= lastNonEmptyIndex; i++) {
      if (lines[i].trim().length > 0) {
        const indent = lines[i].match(/^[\t\s]*/)?.[0].length || 0;
        if (indent < minIndent) {
          minIndent = indent;
        }
      }
    }
    
    // If no indentation found, return trimmed content
    if (minIndent === Infinity || minIndent === 0) {
      // Still trim leading/trailing empty lines
      return lines.slice(firstNonEmptyIndex, lastNonEmptyIndex + 1).join('\n');
    }
    
    // Remove the minimum indentation from all lines, and trim leading/trailing empty lines
    const result = [];
    for (let i = firstNonEmptyIndex; i <= lastNonEmptyIndex; i++) {
      const line = lines[i];
      if (line.trim().length === 0) {
        result.push(''); // Keep empty lines as empty
      } else {
        result.push(line.slice(minIndent));
      }
    }
    
    return result.join('\n');
  }
  
  // Function to extract content inside return statement with balanced parentheses
  function extractReturnContent(content) {
    const returnMatch = content.match(/return\s*\(/);
    if (!returnMatch) return content;
    
    const startIndex = returnMatch.index + returnMatch[0].length;
    let depth = 1;
    let i = startIndex;
    
    // Find matching closing parenthesis by counting parentheses
    while (i < content.length && depth > 0) {
      if (content[i] === '(') {
        depth++;
      } else if (content[i] === ')') {
        depth--;
        if (depth === 0) {
          // Found matching closing parenthesis
          // Don't trim here - preserve original structure for indentation removal
          return content.slice(startIndex, i);
        }
      }
      i++;
    }
    
    return content; // Fallback if no match found
  }
  
  // Extract visible part from ZX code (content inside return (...))
  let truncatedZxContent = extractReturnContent(fullZxContent);
  
  // Remove common leading indentation from ZX truncated content
  truncatedZxContent = removeCommonIndentation(truncatedZxContent);
  
  // Function to extract content after return statement, matching until closing semicolon
  function extractZigReturnContent(content) {
    const returnMatch = content.match(/return\s+/);
    if (!returnMatch) return content;
    
    const startIndex = returnMatch.index + returnMatch[0].length;
    let depth = 0; // Track parentheses, braces, brackets
    let i = startIndex;
    let inString = false;
    let stringChar = null;
    
    // Find matching semicolon by accounting for nested structures
    while (i < content.length) {
      const char = content[i];
      
      // Handle string literals
      if ((char === '"' || char === "'") && (i === 0 || content[i - 1] !== '\\')) {
        if (!inString) {
          inString = true;
          stringChar = char;
        } else if (char === stringChar) {
          inString = false;
          stringChar = null;
        }
      }
      
      // Only process brackets/braces/parentheses outside of strings
      if (!inString) {
        if (char === '(' || char === '{' || char === '[') {
          depth++;
        } else if (char === ')' || char === '}' || char === ']') {
          depth--;
        } else if (char === ';' && depth === 0) {
          // Found matching semicolon
          // Don't trim here - preserve original structure for indentation removal
          return content.slice(startIndex, i);
        }
      }
      
      i++;
    }
    
    return content; // Fallback if no match found
  }
  
  // Store full Zig content if available
  let fullZigContent = '';
  let truncatedZigContent = '';
  
  if (zigCodeElement) {
    fullZigContent = zigCodeElement.textContent || zigCodeElement.innerText;
    
    // Extract visible part from Zig code (content after return)
    truncatedZigContent = extractZigReturnContent(fullZigContent);
    
    // Remove common leading indentation from Zig truncated content
    truncatedZigContent = removeCommonIndentation(truncatedZigContent);
  }
  
  // Function to get cursor position
  function getCaretPosition(element) {
    let position = 0;
    const selection = window.getSelection();
    if (selection.rangeCount > 0) {
      const range = selection.getRangeAt(0);
      const preCaretRange = range.cloneRange();
      preCaretRange.selectNodeContents(element);
      preCaretRange.setEnd(range.endContainer, range.endOffset);
      position = preCaretRange.toString().length;
    }
    return position;
  }
  
  // Function to set cursor position (works with Prism-processed content)
  function setCaretPosition(element, position) {
    const range = document.createRange();
    const selection = window.getSelection();
    let charCount = 0;
    let nodeStack = [element];
    let node, foundStart = false;
    
    // Traverse the DOM tree to find the correct position
    while (!foundStart && (node = nodeStack.pop())) {
      if (node.nodeType === Node.TEXT_NODE) {
        const nextCharCount = charCount + node.textContent.length;
        if (position <= nextCharCount) {
          const offset = Math.min(position - charCount, node.textContent.length);
          range.setStart(node, offset);
          range.setEnd(node, offset);
          foundStart = true;
        }
        charCount = nextCharCount;
      } else if (node.nodeType === Node.ELEMENT_NODE) {
        // Push child nodes in reverse order to maintain document order
        let i = node.childNodes.length;
        while (i--) {
          nodeStack.push(node.childNodes[i]);
        }
      }
    }
    
    if (foundStart) {
      selection.removeAllRanges();
      selection.addRange(range);
    } else {
      // Fallback: set cursor at the end
      const walker = document.createTreeWalker(
        element,
        NodeFilter.SHOW_TEXT,
        null
      );
      let lastNode = null;
      while (walker.nextNode()) {
        lastNode = walker.currentNode;
      }
      if (lastNode) {
        range.setStart(lastNode, lastNode.textContent.length);
        range.setEnd(lastNode, lastNode.textContent.length);
        selection.removeAllRanges();
        selection.addRange(range);
      }
    }
  }
  
  // Function to map cursor position from truncated to full content
  function mapCursorPosition(truncatedPos, truncatedText, fullText, _truncatedContent) {
    // For ZX: find the return statement and map position within it
    const returnMatch = fullText.match(/return\s*\(/);
    if (returnMatch) {
      // Find position within the return statement content
      const returnStart = returnMatch.index + returnMatch[0].length;
      // Extract return content manually (without trimming) for cursor mapping
      let depth = 1;
      let i = returnStart;
      while (i < fullText.length && depth > 0) {
        if (fullText[i] === '(') {
          depth++;
        } else if (fullText[i] === ')') {
          depth--;
          if (depth === 0) {
            break;
          }
        }
        i++;
      }
      const returnContentRaw = fullText.slice(returnStart, i);
      
      // Apply the same transformations as removeCommonIndentation
      // Split into lines first to match the new logic
      const linesOriginal = returnContentRaw.split('\n');
      
      // Find first and last non-empty lines (same logic as removeCommonIndentation)
      let firstNonEmptyIndex = -1;
      let lastNonEmptyIndex = -1;
      for (let j = 0; j < linesOriginal.length; j++) {
        if (linesOriginal[j].trim().length > 0) {
          if (firstNonEmptyIndex === -1) {
            firstNonEmptyIndex = j;
          }
          lastNonEmptyIndex = j;
        }
      }
      
      if (firstNonEmptyIndex === -1) {
        return returnStart + truncatedPos;
      }
      
      // Find minimum indentation among non-empty lines
      let minIndent = Infinity;
      for (let j = firstNonEmptyIndex; j <= lastNonEmptyIndex; j++) {
        if (linesOriginal[j].trim().length > 0) {
          const indent = linesOriginal[j].match(/^[\t\s]*/)?.[0].length || 0;
          if (indent < minIndent) {
            minIndent = indent;
          }
        }
      }
      
      // Map cursor position accounting for line trimming and indentation removal
      const truncatedLines = truncatedText.split('\n');
      let charCount = 0;
      let lineIndex = 0;
      let positionInLine = 0;
      
      // Find which line the cursor is on in truncated content
      for (let i = 0; i < truncatedLines.length; i++) {
        const lineLength = truncatedLines[i].length;
        const nextCharCount = charCount + lineLength;
        if (truncatedPos <= nextCharCount) {
          lineIndex = i;
          positionInLine = truncatedPos - charCount;
          break;
        }
        charCount = nextCharCount + 1; // +1 for newline
      }
      
      // Map truncated line index to original line index
      // The truncated content only includes lines from firstNonEmptyIndex to lastNonEmptyIndex
      const originalLineIndex = firstNonEmptyIndex + lineIndex;
      
      if (originalLineIndex < 0 || originalLineIndex >= linesOriginal.length) {
        return returnStart + truncatedPos;
      }
      
      // Calculate position: sum of all characters before the target line
      let posBeforeLine = 0;
      for (let j = 0; j < originalLineIndex; j++) {
        posBeforeLine += linesOriginal[j].length + 1; // +1 for newline
      }
      
      // Add the indentation that was removed (minIndent) and the position within the line
      return returnStart + posBeforeLine + minIndent + positionInLine;
    }
    return truncatedPos;
  }
  
  // Function to show truncated content
  function showTruncatedContent() {
    zxCodeElement.textContent = truncatedZxContent;
    if (zigCodeElement) {
      zigCodeElement.textContent = truncatedZigContent;
    }
    
    // Re-highlight with Prism.js
    if (typeof Prism !== 'undefined') {
      Prism.highlightElement(zxCodeElement);
      if (zigCodeElement) {
        Prism.highlightElement(zigCodeElement);
      }
    }
  }
  
  // Function to show full content
  function showFullContent(_event) {
    // Check if currently showing truncated content by comparing lengths
    const currentZxText = zxCodeElement.textContent || zxCodeElement.innerText;
    const isTruncated = currentZxText.length < fullZxContent.length || 
                       currentZxText.trim() === truncatedZxContent.trim();
    
    if (isTruncated) {
      // Store cursor position before expanding
      let cursorPosition = 0;
      
      // Use setTimeout to capture cursor position after click/focus event completes
      setTimeout(() => {
        // Get cursor position from the current selection
        cursorPosition = getCaretPosition(zxCodeElement);
        
        // Map cursor position from truncated to full content
        const mappedPosition = mapCursorPosition(cursorPosition, currentZxText, fullZxContent, truncatedZxContent);
        
        // Show full content
        zxCodeElement.textContent = fullZxContent;
        if (zigCodeElement) {
          zigCodeElement.textContent = fullZigContent;
        }
        
        // Re-highlight with Prism.js
        if (typeof Prism !== 'undefined') {
          Prism.highlightElement(zxCodeElement);
          if (zigCodeElement) {
            Prism.highlightElement(zigCodeElement);
          }
        }
        
        // Restore cursor position after a brief delay to allow Prism to process
        // Use requestAnimationFrame to ensure DOM is updated
        requestAnimationFrame(() => {
          setTimeout(() => {
            setCaretPosition(zxCodeElement, mappedPosition);
            // Focus the element to ensure cursor is visible
            zxCodeElement.focus();
          }, 10);
        });
      }, 0);
    }
  }
  
  // Show truncated versions by default
  showTruncatedContent();
  
  // Show full content when ZX code is clicked/focused
  zxCodeElement.addEventListener('focus', showFullContent);
  zxCodeElement.addEventListener('click', showFullContent);
  
  // Show truncated content when ZX code loses focus
  zxCodeElement.addEventListener('blur', showTruncatedContent);
}