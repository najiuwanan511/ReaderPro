import Foundation

// A deliberately finite Java API adapter, not a JVM. Unknown classes remain
// errors; cryptographic operations use the iOS implementations in SourceCrypto.
enum SourceJava {
    static let script = #"""
    java.util.Arrays = {
        copyOfRange:function(value,from,to){
            if(from<0 || from>value.length || to<from) throw Error('Invalid array range');
            var out=Array.from(value).slice(from,to); while(out.length<to-from) out.push(0); return _array(out);
        },
        copyOf:function(value,length){return this.copyOfRange(value,0,length);}
    };
    java.util.HashMap = function(){
        var values={};
        return _methods(values,{
            put:function(key,value){var old=this[key];this[key]=value;return old == null ? null : old;},
            get:function(key){return this[key] == null ? null : this[key];},
            containsKey:function(key){return Object.prototype.hasOwnProperty.call(this,key);},
            keySet:function(){return _array(Object.keys(this));},
            size:function(){return Object.keys(this).length;}
        });
    };
    function _encoded(value){return {encoded:value,getEncoded:function(){return this.encoded;}};}
    function _keySpec(value){return _encoded(value);}
    var _cipher={
        ENCRYPT_MODE:1, DECRYPT_MODE:2,
        getInstance:function(algorithm){
            var key=null,iv=null,mode=0;
            return {
                init:function(operation,spec,parameters){mode=operation;key=spec.encoded;iv=parameters ? parameters.encoded : null;},
                doFinal:function(value){
                    if(mode!==1 && mode!==2) throw Error('Cipher is not initialized');
                    return java._crypt(value,algorithm,key,iv,mode===2,'bytes');
                }
            };
        }
    };
    Packages.javax={crypto:{
        Cipher:_cipher,
        Mac:{getInstance:function(algorithm){
            var key=null;
            return {init:function(spec){key=spec.encoded;},doFinal:function(value){
                if(key==null) throw Error('Mac is not initialized');
                return java.hexDecodeToByteArray(java._hmac(value,algorithm,key,false));
            }};
        }},
        SecretKeyFactory:{getInstance:function(algorithm){
            if(String(algorithm).toUpperCase()!=='DES') throw Error('Unsupported secret key factory: '+algorithm);
            return {generateSecret:function(spec){return _encoded(java.util.Arrays.copyOfRange(spec.encoded,0,8));}};
        }},
        spec:{SecretKeySpec:_keySpec,IvParameterSpec:_keySpec,DESKeySpec:_keySpec}
    }};
    var _signature={getInstance:function(algorithm){
        var key=null,parts=[];
        return {
            initSign:function(value){key=value.encoded;parts=[];},
            update:function(value){parts=parts.concat(Array.from(value));},
            sign:function(){if(key==null)throw Error('Signature is not initialized');return java._rsaSign(parts,key,algorithm);}
        };
    }};
    java.security={
        Signature:_signature,
        KeyFactory:{getInstance:function(algorithm){
            if(String(algorithm).toUpperCase()!=='RSA') throw Error('Unsupported key factory: '+algorithm);
            return {generatePrivate:function(spec){return _encoded(spec.encoded);},generatePublic:function(spec){return _encoded(spec.encoded);}};
        }},
        spec:{PKCS8EncodedKeySpec:_keySpec,X509EncodedKeySpec:_keySpec},interfaces:{}
    };
    java.io={ByteArrayOutputStream:function(){
        var bytes=[];
        return {write:function(value,offset,length){bytes=bytes.concat(Array.from(value).slice(offset || 0,length == null ? value.length : (offset || 0)+length));},
            toByteArray:function(){return bytes;},close:function(){},size:function(){return bytes.length;}};
    }};
    var _base64={
        DEFAULT:0,NO_PADDING:1,NO_WRAP:2,URL_SAFE:8,
        decode:function(value){return java.base64DecodeToByteArray(String(value));},
        decodeStr:function(value){return java.bytesToStr(this.decode(value));},
        encode:function(value){return java.base64Encode(value);},
        encodeToString:function(value,flags){
            var text=java.base64Encode(value);
            if(flags & 8)text=text.replace(/\+/g,'-').replace(/\//g,'_');
            if(flags & 1)text=text.replace(/=+$/,'');
            return text;
        }
    };
    Packages.android={util:{Base64:_base64},os:{Build:{MODEL:'iPhone',MANUFACTURER:'Apple'}}};
    Packages.cn={hutool:{
        core:{codec:{Base64:_base64}},
        crypto:{digest:{DigestUtil:{md5Hex:function(value){return java.digestHex(value,'MD5');},sha256Hex:function(value){return java.digestHex(value,'SHA-256');}}}}
    }};
    function JavaImporter(){
        var scope={};
        Object.defineProperty(scope,'importPackage',{enumerable:false,value:function(){
            for(var i=0;i<arguments.length;i++){
                var pack=arguments[i];if(!pack)throw Error('Unsupported Java package');
                Object.keys(pack).forEach(function(name){scope[name]=pack[name];});
            }
        }});
        scope.importPackage.apply(scope,arguments);
        return scope;
    }
    """#
}
