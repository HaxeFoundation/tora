class Main {
	static function main()
	{
		var r = new utest.Runner();
		r.addCase(new TestFastCgiMultipart());
		utest.ui.Report.create(r);
		r.run();
	}
}

