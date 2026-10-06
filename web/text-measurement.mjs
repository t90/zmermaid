// SPDX-License-Identifier: EPL-2.0
// Mermaid 11.16.1 implementation/behavior references:
// https://github.com/mermaid-js/mermaid/blob/7ecca0cd7f1658ef74f4e7e91f925724ef403bbf/packages/mermaid/src/rendering-util/createText.ts
// https://github.com/mermaid-js/mermaid/blob/7ecca0cd7f1658ef74f4e7e91f925724ef403bbf/packages/mermaid/src/rendering-util/splitText.ts
// Upstream copyright: (c) 2014 - 2022 Knut Sveidqvist.
// Upstream MIT notice: LICENSES/Mermaid-MIT.txt; project license: LICENSE.
// Browser font adapter for native measurement requests. No Mermaid, ELK or
// reference geometry is imported. Dimensions come from real SVG text shaping.
// Replicates createText's normal/strong/em word runs and splitText's fit policy.
// See THIRD-PARTY-NOTICES.txt for upstream attribution.
export function shapeTextRequest(request, document) {
  if(request.schema!=='zmermaid-measurement-request-v1')throw new Error('Invalid text request');
  const ns='http://www.w3.org/2000/svg';
  const make=(name,parent)=>{const e=document.createElementNS(ns,name);parent?.append(e);return e;};
  const svg=make('svg',document.body);
  Object.assign(svg.style,{position:'absolute',left:'-100000px',top:'0',fontFamily:request.font_family,fontSize:'16px'});
  const noLabel=new Set(['small_circle','framed_circle','junction','fork','hourglass','bolt','crossed_circle']);
  function words(label,markdown) {
    return label.replace(/\\n/g,'\n').split('\n').map(line=>{
      const result=[];
      if(!markdown)return line.trim().split(/\s+/u).filter(Boolean).map(content=>({content,type:'normal'}));
      let at=0,type='normal',buffer='';
      function flush(){for(const content of buffer.split(' ').filter(Boolean))result.push({content,type});buffer='';}
      while(at<line.length){
        if(line.startsWith('**',at)){flush();type=type==='strong'?'normal':'strong';at+=2;}
        else if(line[at]==='*'){flush();type=type==='em'?'normal':'em';at++;}
        else buffer+=line[at++];
      }
      flush();return result;
    });
  }
  function appendWords(span,runs){
    for(const [i,run] of runs.entries()){
      const child=make('tspan',span);child.setAttribute('font-style',run.type==='em'?'italic':'normal');
      child.setAttribute('font-weight',run.type==='strong'?'bold':'normal');child.textContent=(i?' ':'')+run.content;
    }
  }
  function measure(item,edge=false){
    const group=make('g',svg),probe=make('text',group);
    group.style.fontSize=`${item.font_size}px`;
    const fits=runs=>{
      probe.replaceChildren();const span=make('tspan',probe);appendWords(span,runs);
      return span.getComputedTextLength()<=(item.unwrapped?Infinity:request.wrapping_width);
    };
    const rows=[];
    for(const line of words(item.label,item.markdown)){
      if(fits(line)){rows.push(line);continue;}
      const pending=line.slice();let current=[];
      while(pending.length){
        let joiner=null;
        if(pending[0].content===' '){joiner={content:' ',type:'normal'};pending.shift();}
        const next=pending.shift()??{content:' ',type:'normal'};
        const trial=[...current,...(joiner?[joiner]:[]),next];
        if(fits(trial)){current=trial;continue;}
        if(current.length){rows.push(current);current=[];pending.unshift(next);continue;}
        const chars=[...new Intl.Segmenter().segment(next.content)].map(x=>x.segment);
        let used=0;
        while(used<chars.length&&fits([{content:chars.slice(0,used+1).join(''),type:next.type}]))used++;
        used=Math.max(used,1);rows.push([{content:chars.slice(0,used).join(''),type:next.type}]);
        if(used<chars.length)pending.unshift({content:chars.slice(used).join(''),type:next.type});
      }
      if(current.length)rows.push(current);
    }
    probe.remove();
    const text=make('text',group);text.setAttribute('y','-10.1');
    // Upstream applies node styles only after the wrapping fit pass.
    text.style.fontSize=`${item.font_size}px`;
    text.style.fontWeight=item.bold?'bold':'normal';text.style.fontStyle=item.italic?'italic':'normal';
    // Mermaid's node CSS centers text too. Anchoring changes the union of
    // different line widths and glyph overhangs, not just its position.
    text.setAttribute('text-anchor','middle');
    for(const [i,row] of rows.entries()){
      const span=make('tspan',text);span.setAttribute('x','0');span.setAttribute('y',`${i*1.1-0.1}em`);span.setAttribute('dy','1.1em');
      if(edge)span.setAttribute('text-anchor','middle');appendWords(span,row);
    }
    const box=text.getBBox(),lines=rows.map(row=>row.map(run=>run.content).join(' '));
    const result={text_width:box.width,text_height:box.height,text_x:box.x,text_y:box.y,lines,runs:rows,font_size:item.font_size};
    group.remove();return result;
  }
  try {
    const nodes=request.nodes.map(node=>({...node,...(noLabel.has(node.shape)?{text_width:0,text_height:0,text_x:0,text_y:0,runs:[],lines:node.shape==='hourglass'?['']:[],font_size:node.font_size}:measure(node)),
      // rectWithTitle uses createLabel(width=Infinity), unlike regular nodes.
      sections:(node.sections||[]).map(label=>({label,...measure({...node,label,unwrapped:true})}))}));
    const edges=request.edges.map(edge=>{
      const bounds=edge.label?measure(edge,true):{text_width:0,text_height:0,text_x:0,text_y:0,lines:[],runs:[],font_size:edge.font_size};
      return {index:edge.index,source:edge.source,target:edge.target,label:edge.label,markdown:edge.markdown,...bounds,width:bounds.text_width+(edge.label?4:0),height:bounds.text_height+(edge.label?4:0)};
    });
    return {schema:'zmermaid-shaped-text-v1',...(request.request_key?{request_key:request.request_key}:{}),nodes:nodes.map(({id,shape,label,markdown,text_width,text_height,text_x,text_y,font_size,lines,runs,sections,padding})=>({id,shape,label,markdown,text_width,text_height,text_x,text_y,font_size,lines,runs,sections,padding})),edges,
      font_family:request.font_family,padding:request.padding,direction:request.direction,
      ...(request.diagram_family?{diagram_family:request.diagram_family}: {})};
  } finally {svg.remove();}
}
