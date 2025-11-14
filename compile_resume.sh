# Fonts: Roboto, FontAwesome, Source Sans Pro
#
# curl -fsSL https://typst.community/typst-install/install.sh | sh
has_typst=$(which typst)

if [[ -z "$has_typst" ]]; then
	echo "downloading typst"
	curl -fsSL https://typst.community/typst-install/install.sh | sh
fi


echo "compiling"
typst compile resume_oct_24.typ resume_short.pdf
echo "generated resume_short.pdf"
cp resume_short.pdf ~/Desktop/Resume_Software_Engineer.pdf 
exit 0
