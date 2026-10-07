EMACS = emacs


README.md: make-readme-markdown.el bpftrace-mode.el
	$(EMACS) --script $< <bpftrace-mode.el >$@ 2>/dev/null

make-readme-markdown.el:
	wget -q -O $@ https://raw.github.com/mgalgs/make-readme-markdown/master/make-readme-markdown.el

.INTERMEDIATE: make-readme-markdown.el
