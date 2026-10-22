/// `PROPFIND` answers in the shapes real servers write them (from their
/// documentation and sources), for `Depth: 0` on a folder.
library;

/// Nextcloud and ownCloud (sabre/dav): `d:` prefixes, extra namespaces,
/// the ETag quoted with `&quot;`, a 404 propstat for what it lacks
/// (docs.nextcloud.com, "Basic APIs": `"6436d084d4805"`).
const nextcloudFolder = '''
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/alice/Mozhi/</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype>
     <d:collection/>
    </d:resourcetype>
    <d:getetag>&quot;6436d084d4805&quot;</d:getetag>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
  <d:propstat>
   <d:prop>
    <d:getcontentlength/>
   </d:prop>
   <d:status>HTTP/1.1 404 Not Found</d:status>
  </d:propstat>
 </d:response>
</d:multistatus>
''';

/// Nextcloud for a file: `getcontentlength` found, an empty resourcetype.
const nextcloudFile = '''
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns"><d:response><d:href>/remote.php/dav/files/alice/Mozhi/mozhi-sync.mozhibackup</d:href><d:propstat><d:prop><d:resourcetype/><d:getetag>&quot;8f3c1e2a&quot;</d:getetag><d:getcontentlength>2048</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
''';

/// Apache mod_dav (and the WebDAV Server of Synology DSM, which is
/// Apache's): live properties in an `lp1:` namespace declared on the
/// response, missing ones with `ns0:`.
const apacheFolder = '''
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">
<D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
<D:href>/webdav/Mozhi/</D:href>
<D:propstat>
<D:prop>
<lp1:resourcetype><D:collection/></lp1:resourcetype>
<lp1:getetag>"1000-5f2b1c3d4e5f6"</lp1:getetag>
</D:prop>
<D:status>HTTP/1.1 200 OK</D:status>
</D:propstat>
<D:propstat>
<D:prop>
<ns0:getcontentlength/>
</D:prop>
<D:status>HTTP/1.1 404 Not Found</D:status>
</D:propstat>
</D:response>
</D:multistatus>
''';

/// `rclone serve webdav` (Go's `golang.org/x/net/webdav`): `D:` prefixes,
/// the namespace declared again on `collection`, no ETag for folders.
const String rcloneFolder = '''
<?xml version="1.0" encoding="UTF-8"?><D:multistatus xmlns:D="DAV:">
<D:response><D:href>/Mozhi/</D:href><D:propstat><D:prop>
<D:resourcetype><D:collection xmlns:D="DAV:"/></D:resourcetype>
</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
<D:propstat><D:prop><D:getetag></D:getetag>
<D:getcontentlength></D:getcontentlength></D:prop>
<D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
</D:response></D:multistatus>
''';

/// A server that writes the DAV: namespace as the default one.
const defaultNamespaceFolder = '''
<?xml version="1.0" encoding="utf-8" ?>
<!-- generated -->
<multistatus xmlns="DAV:">
  <response>
    <href>https://dav.example.org/Mozhi/</href>
    <propstat>
      <prop>
        <resourcetype><collection/></resourcetype>
        <getetag><![CDATA["abc"]]></getetag>
      </prop>
      <status>HTTP/1.1 200 OK</status>
    </propstat>
  </response>
</multistatus>
''';

/// A folder listed without any resourcetype, href ending in `/`.
const String noResourceTypeFolder = '''
<D:multistatus xmlns:D="DAV:"><D:response><D:href>/Mozhi/</D:href>
<D:propstat><D:prop><D:getetag>"x"</D:getetag></D:prop>
<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>
''';

/// A response that reports the resource as missing at response level.
const String missingResponse = '''
<D:multistatus xmlns:D="DAV:"><D:response><D:href>/Mozhi/</D:href>
<D:status>HTTP/1.1 404 Not Found</D:status></D:response>
</D:multistatus>
''';

/// Nextcloud's (sabre/dav) error body for a wrong password.
const nextcloudNotAuthenticated = '''
<?xml version="1.0" encoding="utf-8"?>
<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
  <s:exception>Sabre&#92;DAV&#92;Exception&#92;NotAuthenticated</s:exception>
  <s:message>Username or password was incorrect</s:message>
</d:error>
''';

/// A plain web server's answer to `PROPFIND`.
const String htmlPage = '''
<!DOCTYPE html><html><head><title>Welcome</title></head>
<body><h1>It works!</h1></body></html>
''';
