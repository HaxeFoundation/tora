/**
 * ...
 * @author Constantine
 */

package fcgi;
import haxe.ds.StringMap;

class StatusCode
{
	public static var CODES = {
		var h : StringMap<String> = new StringMap();
		var a = [
			"200", "OK",
			"302", "Found",
			"404", "Not Found",
			"500", "Internal Server Error",
			"301", "Moved Permanently",
			"304", "Not Modified",
			"303", "See Other",
			"403", "Forbidden",
			"307", "Temporary Redirect",
			"401", "Unauthorized",
			"400", "Bad Request",
			"405", "Method Not Allowed",
			"408", "Request Timeout",

			"100", "Continue",
			"101", "Switching Protocols",
			"201", "Created",
			"202", "Accepted",
			"203", "Non-Authoritative Information",
			"204", "No Content",
			"205", "Reset Content",
			"206", "Partial Content",
			"300", "Multiple Choices",
			"305", "Use Proxy",
			"402", "Payment Required",
			"406", "Not Acceptable",
			"407", "Proxy Authentication Required",
			"409", "Conflict",
			"410", "Gone",
			"411", "Length Required",
			"412", "Precondition Failed",
			"413", "Request Entity Too Large",
			"414", "Request-URI Too Long",
			"415", "Unsupported Media Type",
			"416", "Requested Range Not Satisfiable",
			"417", "Expectation Failed",
			"501", "Not Implemented",
			"502", "Bad Gateway",
			"503", "Service Unavailable",
			"504", "Gateway Timeout",
			"505", "HTTP Version Not Supported"
		];
		var it = a.iterator();
		for ( c in it )
			h.set(c, it.next());
		h;
	}
}