var _yt_player={};(function(g){var window=this;var Ra=function(a){return a.split("").reverse().join("")},
Sb=function(a){var b=a.split("");b.push(b.shift());return b.join("")};
g.Uq=function(a){var b=a.indexOf("?");this.base=b<0?a:a.slice(0,b);this.list=[];if(b>=0)for(var c=a.slice(b+1).split("&"),d=0;d<c.length;d++){var e=c[d].indexOf("=");e<0?this.list.push([c[d],""]):this.list.push([c[d].slice(0,e),decodeURIComponent(c[d].slice(e+1))])}};
g.k=g.Uq.prototype;
g.k.get=function(a){for(var b=0;b<this.list.length;b++)if(this.list[b][0]===a)return encodeURIComponent(this.list[b][1])};
g.k.set=function(a,b){for(var c=0;c<this.list.length;c++)if(this.list[c][0]===a)return this.list[c][1]=b,this;this.list.push([a,b]);return this};
g.k.clone=function(){return new g.Uq(this.base)};
var Tz=function(a,b="",c=""){a=new g.Uq(a);a.set("alr","yes");c&&a.set(b||"signature",Ra(c));var d=a.get("n");d&&a.set("n",Sb(decodeURIComponent(d))+"_ok");return a};
var Yx=function(){return{signatureTimestamp:20314,other:1}};
g.Tz=Tz;})(_yt_player);
