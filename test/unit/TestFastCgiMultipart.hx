/*
	Tora - Neko Application Server
	Copyright (C) 2008-2017 Haxe Foundation

	This library is free software; you can redistribute it and/or
	modify it under the terms of the GNU Lesser General Public
	License as published by the Free Software Foundation; either
	version 2.1 of the License, or (at your option) any later version.

	This library is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
	Lesser General Public License for more details.

	You should have received a copy of the GNU Lesser General Public
	License along with this library; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
*/

import fcgi.MultipartParser;
import tora.Code;
import utest.Assert;

class TestFastCgiMultipart {
	public function new() {}

	// simplify a Recipe for easier comparison
	static function s(msg:Recipe)
	{
		if (msg == null)
			return null;
		var data = msg.buffer != null ? msg.buffer.substr(msg.start, msg.length).toString() : null;
		return { code:msg.code, data:data };
	}

	public function test_complete_flow_with_single_feeding()
	{
		var m = new MultipartParser("--foo");
		m.feed('garbage\r\n--foo\r\nContent-Disposition: form-data; name="foo"\r\n\r\nbar\r\n--foo--\r\ngarbage');
		Assert.same({ code:CPartKey, data:"foo" }, s(m.read()));
		Assert.same({ code:CPartData, data:"bar" }, s(m.read()));
		Assert.same({ code:CPartDone, data:null }, s(m.read()));
		Assert.same({ code:CExecute, data:null }, s(m.read()));
	}

	public function test_multiple_parts()
	{
		var m = new MultipartParser("--foo");
		m.feed('--foo\r\nContent-Disposition: form-data; name="foo"\r\n\r\nFOO\r\n--foo\r\n');
		m.feed('Content-Disposition: form-data; name="bar"\r\n\r\nBAR\r\n--foo--');
		Assert.same({ code:CPartKey, data:"foo" }, s(m.read()));
		Assert.same({ code:CPartData, data:"FOO" }, s(m.read()));
		Assert.same({ code:CPartDone, data:null }, s(m.read()));
		Assert.same({ code:CPartKey, data:"bar" }, s(m.read()));
		Assert.same({ code:CPartData, data:"BAR" }, s(m.read()));
		Assert.same({ code:CPartDone, data:null }, s(m.read()));
		Assert.same({ code:CExecute, data:null }, s(m.read()));
	}

	public function test_filenames()
	{
		var m = new MultipartParser("--foo");
		m.feed('--foo\r\nContent-Disposition: form-data; name="foo"; filename="foo.png"\r\n\r\n');
		Assert.same({ code:CPartFilename, data:"foo.png" }, s(m.read()));
		Assert.same({ code:CPartKey, data:"foo" }, s(m.read()));

		var m = new MultipartParser("--foo");
		m.feed('--foo\r\nContent-Disposition: form-data; filename="foo.png"; name="foo"\r\n\r\n');
		Assert.same({ code:CPartFilename, data:"foo.png" }, s(m.read()));
		Assert.same({ code:CPartKey, data:"foo" }, s(m.read()));
	}

	public function test_linebreaks_in_disposition()
	{
		var m = new MultipartParser("--foo");
		m.feed('--foo\r\nContent-Disposition: form-data; name="foo";\r\n  filename="foo.png"\r\n\r\n');
		Assert.same({ code:CPartFilename, data:"foo.png" }, s(m.read()));
		Assert.same({ code:CPartKey, data:"foo" }, s(m.read()));
	}

	public function test_part_has_content_type()
	{
		var m = new MultipartParser("--foo");
		m.feed('--foo\r\nContent-Disposition: form-data; name="foo"\r\nContent-Type: bar\r\n\r\n');
		Assert.same({ code:CPartKey, data:"foo" }, s(m.read()));

		var m = new MultipartParser("--foo");
		m.feed('--foo\r\nContent-Type: bar\r\nContent-Disposition: form-data; name="foo"\r\n\r\n');
		Assert.same({ code:CPartKey, data:"foo" }, s(m.read()));
	}

	public function test_lowercase_header()
	{
		var m = new MultipartParser("--foo");
		m.feed('garbage\r\n--foo\r\ncontent-disposition: form-data; name="foo"\r\n\r\n');
		Assert.same({ code:CPartKey, data:"foo" }, s(m.read()));
	}

	public function test_read_data_with_buffer_breaks()
	{
		var m = new MultipartParser("--foo");
		m.feed('--foo\r\nContent-Dispo');
		Assert.isNull(s(m.read()));

		m.feed('sition: form-data; name="foo"\r\n\r\n');
		Assert.same({ code:CPartKey, data:"foo" }, s(m.read()));
		Assert.isNull(s(m.read()));

		m.feed('bar');
		Assert.same({ code:CPartData, data:"bar" }, s(m.read()));

		Assert.isNull(s(m.read()));

		m.feed('\r\n');
		Assert.isNull(s(m.read()));
		m.feed('-');
		Assert.isNull(s(m.read()));
		m.feed('-fo');
		Assert.isNull(s(m.read()));
		m.feed('ster');
		Assert.same({ code:CPartData, data:"\r\n--foster" }, s(m.read()));

		m.feed('\r\n--fo');
		Assert.isNull(s(m.read()));
		m.feed('o');
		Assert.same({ code:CPartDone, data:null }, s(m.read()));

		m.feed('--');
		Assert.same({ code:CExecute, data:null }, s(m.read()));
	}

	public function test_no_parts()
	{
		var m = new MultipartParser("--foo");
		m.feed('--foo--');
		Assert.same({ code:CExecute, data:null }, s(m.read()));
	}

	public function test_before_first_boundary()
	{
		var m = new MultipartParser("--foo");
		Assert.isNull(s(m.read()));

		m.feed('garbage\r\n');
		Assert.isNull(s(m.read()));

		m.feed('--foo--');
		Assert.same({ code:CExecute, data:null }, s(m.read()));
	}

	public function test_after_last_one()
	{
		var m = new MultipartParser("--foo");
		m.feed('--foo--');
		Assert.same({ code:CExecute, data:null }, s(m.read()));

		// feed: don't store any data
		m.feed("foo");
		Assert.isNull(@:privateAccess m.buf);

		// read: return CExecute, no matter what
		Assert.same({ code:CExecute, data:null }, s(m.read()));
	}

	public function test_missing_boundary()
	{
		var m = new MultipartParser(null);
		Assert.raises(m.read, String);
		m.feed('--foo--');
		Assert.raises(m.read, String);
	}
}

