#!/usr/bin/env python3
"""Generate a table of contents from built HTML pages."""

import re
from pathlib import Path
from html.parser import HTMLParser


class HeadingParser(HTMLParser):
    """Parse HTML and extract heading tags."""
    
    def __init__(self):
        super().__init__()
        self.headings = []
        self.current_tag = None
        self.current_text = []
        
    def handle_starttag(self, tag, attrs):
        if tag in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']:
            self.current_tag = tag
            self.current_text = []
            
    def handle_endtag(self, tag):
        if tag == self.current_tag:
            text = ''.join(self.current_text).strip()
            # Skip footer headings
            if text and not text.startswith('BUILDING THE') and not text.startswith('GET IN TOUCH'):
                self.headings.append((self.current_tag, text))
            self.current_tag = None
            
    def handle_data(self, data):
        if self.current_tag:
            self.current_text.append(data)


def main():
    """Generate TOC for main pages."""
    pages = [
        'index.html',
        'about/index.html', 
        'work/index.html',
        'roadmap/index.html',
        'insights/index.html'
    ]
    
    site_dir = Path(__file__).parent.parent / '_site'
    
    for page in pages:
        path = site_dir / page
        if not path.exists():
            print(f"Skipping {page} - not found")
            continue
            
        content = path.read_text()
        parser = HeadingParser()
        parser.feed(content)
        
        print(f"\n{'='*80}")
        print(f"PAGE: {page}")
        print(f"{'='*80}")
        
        for tag, text in parser.headings[:20]:
            level = int(tag[1])
            indent = "  " * (level - 1)
            clean_text = re.sub(r'\s+', ' ', text)[:70]
            print(f"{indent}{tag.upper()}: {clean_text}")


if __name__ == '__main__':
    main()
