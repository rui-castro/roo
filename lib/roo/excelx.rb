require 'date'
require 'nokogiri'
#require 'spreadsheet'

class Roo::Excelx < Roo::Base
  module Format
    EXCEPTIONAL_FORMATS = {
      'h:mm am/pm' => :date,
      'h:mm:ss am/pm' => :date,
    }

    STANDARD_FORMATS = {
      0 => 'General',
      1 => '0',
      2 => '0.00',
      3 => '#,##0',
      4 => '#,##0.00',
      9 => '0%',
      10 => '0.00%',
      11 => '0.00E+00',
      12 => '# ?/?',
      13 => '# ??/??',
      14 => 'mm-dd-yy',
      15 => 'd-mmm-yy',
      16 => 'd-mmm',
      17 => 'mmm-yy',
      18 => 'h:mm AM/PM',
      19 => 'h:mm:ss AM/PM',
      20 => 'h:mm',
      21 => 'h:mm:ss',
      22 => 'm/d/yy h:mm',
      37 => '#,##0 ;(#,##0)',
      38 => '#,##0 ;[Red](#,##0)',
      39 => '#,##0.00;(#,##0.00)',
      40 => '#,##0.00;[Red](#,##0.00)',
      45 => 'mm:ss',
      46 => '[h]:mm:ss',
      47 => 'mmss.0',
      48 => '##0.0E+0',
      49 => '@',
    }

    def to_type(format)
      format = format.to_s.downcase
      if type = EXCEPTIONAL_FORMATS[format]
        type
      elsif format.include?('#')
        :float
      elsif !format.match(/d+(?![\]])/).nil? || format.include?('y')
        if format.include?('h') || format.include?('s')
          :datetime
        else
          :date
        end
      elsif format.include?('h') || format.include?('s')
        :time
      elsif format.include?('%')
        :percentage
      else
        :float
      end
    end

    module_function :to_type
  end

  # initialization and opening of a spreadsheet file
  # values for packed: :zip
  def initialize(filename, options = {}, deprecated_file_warning = :error)
    if Hash === options
      packed = options[:packed]
      file_warning = options[:file_warning] || :error
    else
      warn 'Supplying `packed` or `file_warning` as separate arguments to `Roo::Excelx.new` is deprecated. Use an options hash instead.'
      packed = options
      file_warning = deprecated_file_warning
    end

    file_type_check(filename,'.xlsx','an Excel-xlsx', file_warning, packed)
    make_tmpdir do |tmpdir|
      filename = download_uri(filename, tmpdir) if uri?(filename)
      filename = unzip(filename, tmpdir) if packed == :zip
      @filename = filename
      unless File.file?(@filename)
        raise IOError, "file #{@filename} does not exist"
      end
      @comments_files = []
      @rels_files = []
      process_zipfile(tmpdir, @filename)
      @workbook_doc = load_xml(File.join(tmpdir, "roo_workbook.xml")).remove_namespaces!
      @shared_table = []
      if File.exist?(File.join(tmpdir, 'roo_sharedStrings.xml'))
        @sharedstring_doc = load_xml(File.join(tmpdir, 'roo_sharedStrings.xml')).remove_namespaces!
        read_shared_strings(@sharedstring_doc)
      end
      @styles_table = []
      @style_definitions = [] # TODO: ??? { |h,k| h[k] = {} }
      if File.exist?(File.join(tmpdir, 'roo_styles.xml'))
        @styles_doc = load_xml(File.join(tmpdir, 'roo_styles.xml')).remove_namespaces!
        read_styles(@styles_doc)
      end
      @sheet_doc = load_xmls(@sheet_files)
      @comments_doc = load_xmls(@comments_files)
      @rels_doc = load_xmls(@rels_files)
    end
    super(filename, options)
    @formula = {}
    @excelx_type = {}
    @excelx_value = {}
    @s_attribute = {} # TODO: ggf. wieder entfernen nur lokal benoetigt
    @comment = {}
    @comments_read = {}
    @hyperlink = {}
    @hyperlinks_read = {}
  end

  def method_missing(m,*args)
    # is method name a label name
    read_labels
    if @label.has_key?(m.to_s)
      sheet ||= @default_sheet
      read_cells(sheet)
      row,col = label(m.to_s)
      cell(row,col)
    else
      # call super for methods like #a1
      super
    end
  end

  # Returns the content of a spreadsheet-cell.
  # (1,1) is the upper left corner.
  # (1,1), (1,'A'), ('A',1), ('a',1) all refers to the
  # cell at the first line and first row.
  def cell(row, col, sheet=nil)
    sheet ||= @default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    if celltype(row,col,sheet) == :date
      yyyy,mm,dd = @cell[sheet][[row,col]].split('-')
      Date.new(yyyy.to_i,mm.to_i,dd.to_i)
    elsif celltype(row,col,sheet) == :datetime
      create_datetime_from( @cell[sheet][[row,col]] )
    else
      @cell[sheet][[row,col]]
    end
  end

  # Returns the formula at (row,col).
  # Returns nil if there is no formula.
  # The method #formula? checks if there is a formula.
  def formula(row,col,sheet=nil)
    sheet ||= @default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    @formula[sheet][[row,col]] && @formula[sheet][[row,col]]
  end
  alias_method :formula?, :formula

    # returns each formula in the selected sheet as an array of elements
  # [row, col, formula]
  def formulas(sheet=nil)
    sheet ||= @default_sheet
    read_cells(sheet)
    if @formula[sheet]
      @formula[sheet].map do |coord, formula|
        [coord[0], coord[1], formula]
      end
    else
      []
    end
  end

  class Font
    attr_accessor :bold, :italic, :underline

    def bold?
      @bold == true
    end

    def italic?
      @italic == true
    end

    def underline?
      @underline == true
    end
  end

  # Given a cell, return the cell's style
  def font(row, col, sheet=nil)
    sheet ||= @default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    s_attribute = @s_attribute[sheet][[row,col]]
    s_attribute ||= 0
    s_attribute = s_attribute.to_i
    @style_definitions[s_attribute]
  end

  # returns the type of a cell:
  # * :float
  # * :string,
  # * :date
  # * :percentage
  # * :formula
  # * :time
  # * :datetime
  def celltype(row,col,sheet=nil)
    sheet ||= @default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    if @formula[sheet][[row,col]]
      :formula
    else
      @cell_type[sheet][[row,col]]
    end
  end

  # returns the internal type of an excel cell
  # * :numeric_or_formula
  # * :string
  # Note: this is only available within the Excelx class
  def excelx_type(row,col,sheet=nil)
    sheet ||= @default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    @excelx_type[sheet][[row,col]]
  end

  # returns the internal value of an excelx cell
  # Note: this is only available within the Excelx class
  def excelx_value(row,col,sheet=nil)
    sheet ||= @default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    @excelx_value[sheet][[row,col]]
  end

  # returns the internal format of an excel cell
  def excelx_format(row,col,sheet=nil)
    sheet ||= @default_sheet
    read_cells(sheet)
    row,col = normalize(row,col)
    s = @s_attribute[sheet][[row,col]]
    attribute2format(s).to_s
  end

  # returns an array of sheet names in the spreadsheet
  def sheets
    @workbook_doc.xpath("//sheet").map do |sheet|
      sheet['name']
    end
  end

  # shows the internal representation of all cells
  # for debugging purposes
  def to_s(sheet=nil)
    sheet ||= @default_sheet
    read_cells(sheet)
    @cell[sheet].inspect
  end

  # returns the row,col values of the labelled cell
  # (nil,nil) if label is not defined
  def label(labelname)
    read_labels
    if @label.empty? || !@label.has_key?(labelname)
      [nil,nil,nil]
    else
      [@label[labelname][1].to_i,
        self.class.letter_to_number(@label[labelname][2]),
        @label[labelname][0]]
    end
  end

  # Returns an array which all labels. Each element is an array with
  # [labelname, [row,col,sheetname]]
  def labels
    # sheet ||= @default_sheet
    # read_cells(sheet)
    read_labels
    @label.map do |label|
      [ label[0], # name
        [ label[1][1].to_i, # row
          self.class.letter_to_number(label[1][2]), # column
          label[1][0], # sheet
        ] ]
    end
  end

  def hyperlink?(row,col,sheet=nil)
    hyperlink(row, col, sheet) != nil
  end

  # returns the hyperlink at (row/col)
  # nil if there is no hyperlink
  def hyperlink(row,col,sheet=nil)
    sheet ||= @default_sheet
    read_hyperlinks(sheet) unless @hyperlinks_read[sheet]
    row,col = normalize(row,col)
    @hyperlink[sheet] && @hyperlink[sheet][[row,col]]
  end

  # returns the comment at (row/col)
  # nil if there is no comment
  def comment(row,col,sheet=nil)
    sheet ||= @default_sheet
    #read_cells(sheet)
    read_comments(sheet) unless @comments_read[sheet]
    row,col = normalize(row,col)
    @comment[sheet] && @comment[sheet][[row,col]]
  end

  # true, if there is a comment
  def comment?(row,col,sheet=nil)
    comment(row,col,sheet) != nil
  end

  # returns each comment in the selected sheet as an array of elements
  # [row, col, comment]
  def comments(sheet=nil)
    sheet ||= @default_sheet
    read_comments(sheet) unless @comments_read[sheet]
    if @comment[sheet]
      @comment[sheet].each.collect do |elem|
        [elem[0][0],elem[0][1],elem[1]]
      end
    else
      []
    end
  end

  private

  def load_xmls(paths)
    paths.compact.map do |item|
      load_xml(item).remove_namespaces!
    end
  end

  # helper function to set the internal representation of cells
  def set_cell_values(sheet,x,y,i,v,value_type,formula,
      excelx_type=nil,
      excelx_value=nil,
      s_attribute=nil)
    key = [y,x+i]
    @cell_type[sheet] ||= {}
    @cell_type[sheet][key] = value_type
    @formula[sheet] ||= {}
    @formula[sheet][key] = formula if formula
    @cell[sheet] ||= {}
    @cell[sheet][key] =
      case @cell_type[sheet][key]
      when :float
        v.to_f
      when :string
        v
      when :date
        (base_date+v.to_i).strftime("%Y-%m-%d")
      when :datetime
        (base_date+v.to_f.round(6)).strftime("%Y-%m-%d %H:%M:%S.%N")
      when :percentage
        v.to_f
      when :time
        v.to_f*(24*60*60)
      else
        v
      end

    #@cell[sheet][key] = Spreadsheet::Link.new(@hyperlink[sheet][key], @cell[sheet][key].to_s) if hyperlink?(y,x+i)
    @excelx_type[sheet] ||= {}
    @excelx_type[sheet][key] = excelx_type
    @excelx_value[sheet] ||= {}
    @excelx_value[sheet][key] = excelx_value
    @s_attribute[sheet] ||= {}
    @s_attribute[sheet][key] = s_attribute
  end

  def read_cell_from_xml(sheet, cell_xml)
    c = cell_xml
    s_attribute = c['s'].to_i   # should be here
    # c: <c r="A5" s="2">
    # <v>22606</v>
    # </c>, format: , tmp_type: float
    value_type =
        case c['t']
          when 's'
            :shared
          when 'b'
            :boolean
          # 2011-02-25 BEGIN
          when 'str'
            :string
          # 2011-02-25 END
          # 2011-09-15 BEGIN
          when 'inlineStr'
            :inlinestr
          # 2011-09-15 END
          else
            format = attribute2format(s_attribute)
            Format.to_type(format)
        end
    formula = nil
    c.children.each do |cell|
      case cell.name
        when 'is'
          cell.children.each do |is|
            if is.name == 't'
              inlinestr_content = is.content
              value_type = :string
              v = inlinestr_content
              excelx_type = :string
              y, x = self.class.split_coordinate(c['r'])
              excelx_value = inlinestr_content #cell.content
              set_cell_values(sheet,x,y,0,v,value_type,formula,excelx_type,excelx_value,s_attribute)
            end
          end
        when 'f'
          formula = cell.content
        when 'v'
          if [:time, :datetime].include?(value_type) && cell.content.to_f >= 1.0
            value_type =
                if (cell.content.to_f - cell.content.to_f.floor).abs > 0.000001
                  :datetime
                else
                  :date
                end
          end
          excelx_type = [:numeric_or_formula,format.to_s]
          excelx_value = cell.content
          v =
            case value_type
            when :shared
              value_type = :string
              excelx_type = :string
              @shared_table[cell.content.to_i]
            when :boolean
              (cell.content.to_i == 1 ? 'TRUE' : 'FALSE')
            when :date
              cell.content
            when :time
              cell.content
            when :datetime
              cell.content
            when :formula
              cell.content.to_f #TODO: !!!!
            when :string
              excelx_type = :string
              cell.content
            else
              value_type = :float
              cell.content
            end
          y, x = self.class.split_coordinate(c['r'])
          set_cell_values(sheet,x,y,0,v,value_type,formula,excelx_type,excelx_value,s_attribute)
      end
    end
  end

  # read all cells in the selected sheet
  def read_cells(sheet=nil)
    sheet ||= @default_sheet
    validate_sheet!(sheet)
    return if @cells_read[sheet]

    @sheet_doc[sheets.index(sheet)].xpath("/worksheet/sheetData/row/c").each do |c|
      read_cell_from_xml(sheet, c)
    end
    @cells_read[sheet] = true
    # begin comments
=begin
Datei xl/comments1.xml
  <?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
  <comments xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <authors>
      <author />
    </authors>
    <commentList>
      <comment ref="B4" authorId="0">
        <text>
          <r>
            <rPr>
              <sz val="10" />
              <rFont val="Arial" />
              <family val="2" />
            </rPr>
            <t>Kommentar fuer B4</t>
          </r>
        </text>
      </comment>
      <comment ref="B5" authorId="0">
        <text>
          <r>
            <rPr>
            <sz val="10" />
            <rFont val="Arial" />
            <family val="2" />
          </rPr>
          <t>Kommentar fuer B5</t>
        </r>
      </text>
    </comment>
  </commentList>
  </comments>
=end
=begin
    if @comments_doc[self.sheets.index(sheet)]
      read_comments(sheet)
    end
=end
    #end comments
  end

  # Reads all comments from a sheet
  def read_comments(sheet=nil)
    sheet ||= @default_sheet
    validate_sheet!(sheet)
    n = self.sheets.index(sheet)
    return unless @comments_doc[n] #>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    @comments_doc[n].xpath("//comments/commentList/comment").each do |comment|
      ref = comment.attributes['ref'].to_s
      row,col = self.class.split_coordinate(ref)
      comment.xpath('./text/r/t').each do |text|
        @comment[sheet] ||= {}
        @comment[sheet][[row,col]] = text.text
      end
    end
    @comments_read[sheet] = true
  end

  # Reads all hyperlinks from a sheet
  def read_hyperlinks(sheet=nil)
    sheet ||= @default_sheet
    validate_sheet!(sheet)
    n = self.sheets.index(sheet)
    if rels_doc = @rels_doc[n]
      rels = Hash[rels_doc.xpath("/Relationships/Relationship").map do |r|
        [r.attribute('Id').text, r]
      end]
      @sheet_doc[n].xpath("/worksheet/hyperlinks/hyperlink").each do |h|
        if h.attribute('id') && rel_element = rels[h.attribute('id').text]
          row,col = self.class.split_coordinate(h.attributes['ref'].to_s)
          @hyperlink[sheet] ||= {}
          @hyperlink[sheet][[row,col]] = rel_element.attribute('Target').text
        end
      end
    end
    @hyperlinks_read[sheet] = true
  end

  def read_labels
    @label ||= Hash[@workbook_doc.xpath("//definedName").map do |defined_name|
      # "Sheet1!$C$5"
      sheet, coordinates = defined_name.text.split('!$', 2)
      col,row = coordinates.split('$')
      [defined_name['name'], [sheet,row,col]]
    end]
  end

  # Extracts all needed files from the zip file
  def process_zipfile(tmpdir, zipfilename)
    @sheet_files = []
    Roo::ZipFile.open(zipfilename) {|zf|
      zf.entries.each {|entry|
        entry_name = entry.to_s.downcase

        path =
          if entry_name.end_with?('workbook.xml')
            "#{tmpdir}/roo_workbook.xml"
          elsif entry_name.end_with?('sharedstrings.xml')
            "#{tmpdir}/roo_sharedStrings.xml"
          elsif entry_name.end_with?('styles.xml')
            "#{tmpdir}/roo_styles.xml"
          elsif entry_name =~ /sheet([0-9]+)?.xml$/
            nr = $1
            path = "#{tmpdir}/roo_sheet#{nr.to_i}"

            # Numbers 3.1 exports first sheet without sheet number. Such sheets
            # are always added to the beginning of the array which, naturally,
            # causes other sheets to be pushed to the next index which could
            # lead to sheet references getting overwritten, so we need to
            # handle that case specifically.
            if nr
              sheet_files_index = nr.to_i - 1
              sheet_files_index += 1 if @sheet_files[sheet_files_index]
              @sheet_files[sheet_files_index] = path
            else
              @sheet_files.unshift path
              path
            end
          elsif entry_name =~ /comments([0-9]+).xml$/
            nr = $1
            @comments_files[nr.to_i-1] = "#{tmpdir}/roo_comments#{nr}"
          elsif entry_name =~ /sheet([0-9]+).xml.rels$/
            nr = $1
            @rels_files[nr.to_i-1] = "#{tmpdir}/roo_rels#{nr}"
          end
        if path
          extract_file(zf, entry, path)
        end
      }
    }
  end

  def extract_file(source_zip, entry, destination_path)
    File.open(destination_path,'wb') {|f|
      f << source_zip.read(entry)
    }
  end

  # read the shared strings xml document
  def read_shared_strings(doc)
    doc.xpath("/sst/si").each do |si|
      shared_table_entry = ''
      si.children.each do |elem|
        if elem.name == 'r' and elem.children
          elem.children.each do |r_elem|
            if r_elem.name == 't'
              shared_table_entry << r_elem.content
            end
          end
        end
        if elem.name == 't'
          shared_table_entry = elem.content
        end
      end
      @shared_table << shared_table_entry
    end
  end

  # read the styles elements of an excelx document
  def read_styles(doc)
    @cellXfs = []

    @numFmts = Hash[doc.xpath("//numFmt").map do |numFmt|
      [numFmt['numFmtId'], numFmt['formatCode']]
    end]
    fonts = doc.xpath("//fonts/font").map do |font_el|
      Font.new.tap do |font|
        font.bold = !font_el.xpath('./b').empty?
        font.italic = !font_el.xpath('./i').empty?
        font.underline = !font_el.xpath('./u').empty?
      end
    end

    doc.xpath("//cellXfs").each do |xfs|
      xfs.children.each do |xf|
        @cellXfs << xf['numFmtId']
        @style_definitions << fonts[xf['fontId'].to_i]
      end
    end
  end

  # convert internal excelx attribute to a format
  def attribute2format(s)
    id = @cellXfs[s.to_i]
    @numFmts[id] || Format::STANDARD_FORMATS[id.to_i]
  end

  def base_date
    @base_date ||=
      begin
        # Default to 1900 (minus one day due to excel quirk) but use 1904 if
        # it's set in the Workbook's workbookPr
        # http://msdn.microsoft.com/en-us/library/ff530155(v=office.12).aspx
        @workbook_doc.xpath("//workbookPr[date1904]").each do |workbookPr|
          if workbookPr["date1904"] =~ /true|1/i
            return Date.new(1904,01,01)
          end
        end
        Date.new(1899,12,30)
      end
  end

  def create_datetime_from(datetime_string)
    date_part,time_part = round_time_from(datetime_string).split(' ')
    yyyy,mm,dd = date_part.split('-')
    hh,mi,ss = time_part.split(':')
    DateTime.civil(yyyy.to_i,mm.to_i,dd.to_i,hh.to_i,mi.to_i,ss.to_i)
  end

  def round_time_from(datetime_string)
    date_part,time_part = datetime_string.split(' ')
    yyyy,mm,dd = date_part.split('-')
    hh,mi,ss = time_part.split(':')
    Time.new(yyyy.to_i, mm.to_i, dd.to_i, hh.to_i, mi.to_i, ss.to_r).round(0).strftime("%Y-%m-%d %H:%M:%S")
  end
end
