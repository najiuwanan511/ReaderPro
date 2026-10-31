import XCTest
@testable import ReaderPro

final class JavaCryptoTests: XCTestCase {
    func testJavaStringContentIsReturnedAsTextAndListsRemainJSON() throws {
        let failures = RuleFailures()
        try LegadoJSCtx.$failures.withValue(failures) {
            let text = LegadoJS.run("new Packages.java.lang.String(java.strToBytes('首段\\n正文'))", input: "", baseUrl: "https://example.org", sourceKey: "", sourceUrl: "https://example.org")
            XCTAssertEqual(text, "首段\n正文")
            let list = LegadoJS.run("[new Packages.java.lang.String('甲'),new Packages.java.lang.String('乙')]", input: "", baseUrl: "https://example.org", sourceKey: "", sourceUrl: "https://example.org")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String], ["甲", "乙"])
            try failures.check()
        }
    }

    func testJavaImporterAESDESHMACAndBinaryCodecs() throws {
        let failures = RuleFailures()
        try LegadoJSCtx.$failures.withValue(failures) {
            let output = LegadoJS.run(#"""
            var importer=new JavaImporter();
            importer.importPackage(Packages.java.lang,Packages.javax.crypto,Packages.javax.crypto.spec,Packages.java.util);
            with(importer) {
                var key=SecretKeySpec(java.hexDecodeToByteArray('2b7e151628aed2a6abf7158809cf4f3c'),'AES');
                var iv=IvParameterSpec(java.hexDecodeToByteArray('000102030405060708090a0b0c0d0e0f'));
                var cipher=Cipher.getInstance('AES/CBC/NoPadding');
                cipher.init(Cipher.ENCRYPT_MODE,key,iv);
                var encrypted=cipher.doFinal(java.hexDecodeToByteArray('6bc1bee22e409f96e93d7e117393172a'));
                if(java.base64Encode(encrypted)!=='dkmrrIEZskbO6Y6bEukZfQ==') throw Error('NIST AES');
                cipher.init(Cipher.DECRYPT_MODE,key,iv);
                if(java.base64Encode(cipher.doFinal(encrypted))!=='a8G+4i5An5bpPX4Rc5MXKg==') throw Error('AES decrypt');
                var des=Cipher.getInstance('DES/ECB/NoPadding');
                var desKey=SecretKeyFactory.getInstance('DES').generateSecret(DESKeySpec(java.hexDecodeToByteArray('133457799bbcdff1')));
                des.init(1,desKey);
                if(java.base64Encode(des.doFinal(java.hexDecodeToByteArray('0123456789abcdef')))!=='hegTVA8KtAU=') throw Error('DES vector');
                var mac=Mac.getInstance('HmacSHA256');
                mac.init(SecretKeySpec(java.hexDecodeToByteArray('0b'.repeat(20)),'HmacSHA256'));
                if(java.base64Encode(mac.doFinal(String('Hi There').getBytes('UTF-8')))!=='sDRMYdjbOFNcqK/OrwvxK4gdwgDJgz2nJuk3bC4yz/c=') throw Error('RFC4231 HMAC');
                if(String(java.strToBytes('中文')).toString()!=='中文') throw Error('Java String bytes');
                if(Arrays.copyOfRange([1,2],1,4).join(',')!=='2,0,0') throw Error('Arrays range');
                var map=new HashMap(); map.put('key','value');
                if(map.get('key')!=='value' || map.size()!==1 || JSON.stringify(map)!=='{"key":"value"}')throw Error('HashMap');
            }
            var binary=[0,255,128,1];
            if(Packages.android.util.Base64.encodeToString(binary,2)!=='AP+AAQ==')throw Error('Android Base64');
            if(Packages.android.util.Base64.encodeToString(binary,9)!=='AP-AAQ')throw Error('URL-safe Base64');
            if(Packages.cn.hutool.core.codec.Base64.decode('AP+AAQ==').join(',')!=='0,255,128,1')throw Error('Hutool Base64');
            if(Packages.cn.hutool.crypto.digest.DigestUtil.md5Hex('abc')!=='900150983cd24fb0d6963f7d28e17f72')throw Error('Hutool MD5');
            'passed';
            """#, input: "", baseUrl: "https://example.org", sourceKey: "", sourceUrl: "https://example.org")
            XCTAssertEqual(output, "passed")
            try failures.check()
        }
    }

    func testJavaRSASignaturesMatchIndependentOpenSSLVectors() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rsa-vector", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        let message = Data(try XCTUnwrap(fixture["message"]).utf8)
        for format in ["privatePKCS8", "privatePKCS1"] {
            let key = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(fixture[format])))
            for algorithm in ["sha1", "sha256"] {
                let signed = try SourceCrypto.rsaSign(message, key: key, algorithm: algorithm + "WithRSA")
                XCTAssertEqual(signed.base64EncodedString(), fixture[algorithm])
            }
        }
        let failures = RuleFailures()
        try LegadoJSCtx.$failures.withValue(failures) {
            let output = LegadoJS.run(#"""
            var fixture=JSON.parse(result),importer=new JavaImporter();
            importer.importPackage(Packages.java.lang,Packages.java.security,Packages.java.security.spec,Packages.java.util);
            with(importer) {
                var spec=new PKCS8EncodedKeySpec(Base64.getDecoder().decode(fixture.privatePKCS8));
                var key=KeyFactory.getInstance('RSA').generatePrivate(spec);
                var signature=Signature.getInstance('SHA256WithRSA');signature.initSign(key);
                var input=new String(fixture.message).getBytes('UTF-8');
                signature.update(input.slice(0,5));signature.update(input.slice(5));
                var signed=Base64.getEncoder().encodeToString(signature.sign());
            }
            signed;
            """#, input: String(decoding: try JSONSerialization.data(withJSONObject: fixture), as: UTF8.self), baseUrl: "https://example.org", sourceKey: "", sourceUrl: "https://example.org")
            XCTAssertEqual(output, fixture["sha256"])
            try failures.check()
        }
    }
}
