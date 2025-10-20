package Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use JSON qw(encode_json decode_json);
use CGI;
use C4::Auth qw(get_template_and_user);
use C4::Context;
use DBI;
use LWP::UserAgent;

our $VERSION = "1.48";
our $metadata = {
    name            => 'CraftMyPDF Integration',
    author          => 'Rudy Hinojosa, Lightwave Library',
    description     => 'Integrates Koha guided reports with CraftMyPDF API for synchronous PDF generation and direct download.',
    date_authored   => '2025-10-12',
    date_updated    => '2025-10-16',
    minimum_version => '18.00',
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;
    $args->{metadata} = $metadata;
    $args->{metadata}->{class} = $class;
    my $self = $class->SUPER::new($args);
    return $self;
}

sub configure {
    my ( $self ) = @_;
    my $cgi = $self->{'cgi'} || CGI->new;

    unless ( $cgi->param('save') ) {
        my ( $template, $loggedinuser, $cookie );
        eval {
            ( $template, $loggedinuser, $cookie ) = get_template_and_user({
                template_name   => $self->mbf_path('configure.tt'),
                query           => $cgi,
                type            => 'intranet',
                authnotrequired => 0,
                debug           => 1,
            });
        };
        if ($@) {
            warn "CraftMyPDF: Failed to load template: $@";
            print $cgi->header(-status => 500);
            print "Internal Server Error: Failed to load configure.tt";
            return;
        }

        my $dbh = C4::Context->dbh or do {
            warn "CraftMyPDF: Failed to get database handle";
            print $cgi->header(-status => 500);
            print "Internal Server Error: Database connection failed";
            return;
        };

        my @configs;
        # Try to select including complex_json. If the column doesn't exist (older installs),
        # attempt to add it and fall back to selecting without it, defaulting to '0'.
        my $select_ok = 0;
        eval {
            my $sth = $dbh->prepare("SELECT id, report_id, webhook, api_key, template_id, COALESCE(complex_json, '0') AS complex_json FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs");
            $sth->execute();
            while (my $row = $sth->fetchrow_hashref) {
                push @configs, $row;
            }
            $select_ok = 1;
        };
        if (!$select_ok) {
            warn "CraftMyPDF: SELECT with complex_json failed: $@";
            # Try to add the column (non-fatal if it fails)
            eval {
                $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs ADD COLUMN complex_json VARCHAR(1) DEFAULT '0' AFTER template_id");
                warn "CraftMyPDF: Added missing complex_json column to configs table";
            };
            if ($@) {
                warn "CraftMyPDF: Could not add complex_json column (continuing): $@";
            }

            # Fallback: select without complex_json and set default
            eval {
                my $sth2 = $dbh->prepare("SELECT id, report_id, webhook, api_key, template_id FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs");
                $sth2->execute();
                while (my $row = $sth2->fetchrow_hashref) {
                    $row->{complex_json} = '0';
                    push @configs, $row;
                }
                $select_ok = 1;
            };
            if (!$select_ok) {
                warn "CraftMyPDF: Database error in configure (fallback select failed): $@";
                print $cgi->header(-status => 500);
                print "Internal Server Error: Database query failed";
                return;
            }
        }

        $template->param(
            CLASS              => 'Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF',
            METHOD             => 'configure',
            api_key            => $self->retrieve_data('api_key') || '',
            delete_on_uninstall => $self->retrieve_data('delete_on_uninstall') || '0',
            configs            => \@configs,
        );
        print $cgi->header(
            {
                -type     => 'text/html',
                -charset  => 'UTF-8',
                -encoding => 'UTF-8',
                -cookie   => $cookie,
            }
        );
        print $template->output();
    } else {
            my $api_key = $cgi->param('api_key') || '';
        unless ($api_key) {
            print $cgi->header(-status => 400);
            print "Error: API key is required";
            return;
        }
        my $delete_on_uninstall = $cgi->param('delete_on_uninstall') ? '1' : '0';
        eval {
            $self->store_data({
                api_key            => $api_key,
                delete_on_uninstall => $delete_on_uninstall
            });
            my $dbh = C4::Context->dbh or die "Failed to get database handle";
            $dbh->do("DELETE FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs");
            my @report_ids = $cgi->multi_param('report_id[]');
            my @template_ids = $cgi->multi_param('template_id[]');
            my @complex_flags = $cgi->multi_param('complex_json[]');
            my $sth = $dbh->prepare("INSERT INTO koha_plugin_com_lightwavelibrary_craftmypdf_configs (report_id, webhook, api_key, template_id, complex_json) VALUES (?, '', ?, ?, ?)");
            for my $i (0 .. $#report_ids) {
                next unless $report_ids[$i] && $template_ids[$i];
                my $complex = ($complex_flags[$i] && $complex_flags[$i] eq '1') ? '1' : '0';
                $sth->execute($report_ids[$i], $api_key, $template_ids[$i], $complex);
            }
        };
        if ($@) {
            warn "CraftMyPDF: Error saving configuration: $@";
            print $cgi->header(-status => 500);
            print "Internal Server Error: Failed to save configuration";
            return;
        }
        $self->go_home();
    }
}

sub fetch_templates {
    my ( $self ) = @_;
    my $cgi = $self->{'cgi'} || CGI->new;
    my $api_key = $cgi->param('api_key') || '';
    unless ($api_key) {
        warn "CraftMyPDF: fetch_templates failed - no API key provided";
        return $self->output_json(encode_json({ error => "No API key provided" }), 400);
    }

    my $ua = LWP::UserAgent->new;
    my $response = $ua->get(
        "https://api.craftmypdf.com/v1/list-templates?limit=300&offset=0",
        'X-API-KEY' => $api_key,
        'Content-Type' => 'application/json'
    );
    if ($response->is_success) {
        my $data = decode_json($response->decoded_content);
        warn "CraftMyPDF: Raw API response: " . $response->decoded_content;
        if ($data->{status} eq 'success' && $data->{templates}) {
            my @mapped_templates = map {
                {
                    templateId => $_->{template_id},
                    name       => $_->{name},
                    status     => $_->{status},
                    created_at => $_->{created_at},
                    updated_at => $_->{updated_at}
                }
            } @{$data->{templates}};
            warn "CraftMyPDF: Templates fetched successfully: " . encode_json(\@mapped_templates);
            return $self->output_json(encode_json(\@mapped_templates));
        } else {
            warn "CraftMyPDF: Invalid response format: " . $response->decoded_content;
            return $self->output_json(encode_json({ error => "Invalid response format from CraftMyPDF API" }), 500);
        }
    } else {
        warn "CraftMyPDF: Failed to fetch templates: " . $response->status_line . " - " . $response->decoded_content;
        return $self->output_json(encode_json({ error => "Failed to fetch templates: " . $response->status_line }), 500);
    }
}

sub intranet_js {
    my ( $self ) = @_;
    return <<'END_JS';
<script type="text/javascript" src="https://cdnjs.cloudflare.com/ajax/libs/PapaParse/5.3.2/papaparse.min.js"></script>
<script type="text/javascript">
(function() {
    var buttonAdded = false;

    function cleanText(text) {
        var div = document.createElement('div');
        div.innerHTML = text;
        return div.textContent || div.innerText || '';
    }

    function csvToJson(csv, report_id) {
        console.log('CraftMyPDF: Raw CSV for report ID ' + report_id + ' = ', csv);
        csv = csv.replace(/\r\n|\r/g, '\n').replace(/<[^>]+>|&[^;]+;/g, '').replace(/""/g, '"');
        console.log('CraftMyPDF: Processed CSV for report ID ' + report_id + ' = ', csv);
        try {
            var parsed = Papa.parse(csv, {
                header: true,
                skipEmptyLines: true,
                transform: function(value) {
                    return cleanText(value).trim();
                }
            });
            console.log('CraftMyPDF: Parsed CSV for report ID ' + report_id + ' = ', parsed);
            if (parsed.errors.length > 0) {
                console.error('CraftMyPDF: CSV parsing errors for report ID ' + report_id + ': ', parsed.errors);
            }
            var result = parsed.data.map(row => {
                var newRow = {};
                for (var key in row) {
                    if (key !== 'biblionumber') {
                        newRow[key] = row[key];
                    }
                }
                return newRow;
            });
            console.log('CraftMyPDF: JSON result length for report ID ' + report_id + ' = ' + result.length);
            return result;
        } catch (e) {
            console.error('CraftMyPDF: CSV parsing failed for report ID ' + report_id + ': ', e);
            return [];
        }
    }

    function tableToJson(report_id) {
        console.log('CraftMyPDF: Attempting to parse table data for report ID ' + report_id);
        var table = $('table:has(thead):has(tbody)').first();
        if (!table.length) {
            console.error('CraftMyPDF: No table found for report ID ' + report_id);
            return [];
        }
        var headers = table.find('thead th').map(function() {
            return cleanText($(this).html()).trim();
        }).get().filter(h => h !== '');
        console.log('CraftMyPDF: Table headers for report ID ' + report_id + ' = ', headers);
        var result = [];
        table.find('tbody tr').each(function() {
            var row = $(this).find('td').map(function() {
                return cleanText($(this).html()).trim();
            }).get();
            console.log('CraftMyPDF: Raw table row for report ID ' + report_id + ' = ', row);
            if (row.length >= headers.length) {
                var obj = {};
                headers.forEach((header, index) => {
                    if (header !== 'biblionumber') {
                        obj[header] = row[index] !== undefined ? row[index] : '';
                    }
                });
                result.push(obj);
            } else {
                console.warn('CraftMyPDF: Skipping malformed table row for report ID ' + report_id + ': ', row);
            }
        });
        console.log('CraftMyPDF: Table JSON result length for report ID ' + report_id + ' = ' + result.length);
        return result;
    }

    function sendPayloadToCraft(originalData, payload, apiKey, report_id) {
        // Ensure payload.data is a string (CraftMyPDF accepts either a stringified JSON or an object,
        // but examples and some template engines expect a string). Stringify to be explicit.
        try {
            if (payload && typeof payload.data !== 'string') {
                payload.data = JSON.stringify(payload.data);
            }
        } catch (stringifyError) {
            console.error('CraftMyPDF: Failed to stringify payload.data for report ID ' + report_id + ':', stringifyError);
            alert('Failed to prepare report data for PDF generation. See console for details.');
            return;
        }

        console.log('CraftMyPDF: Preparing payload for report ID ' + report_id + ' (template ' + (payload && payload.template_id) + ')');
        var requestUrl = 'https://api.craftmypdf.com/v1/create';
        var requestHeaders = {
            'X-API-KEY': apiKey,
            'Content-Type': 'application/json'
        };
        var requestBody = null;
        try {
            requestBody = JSON.stringify(payload);
        } catch (rbErr) {
            console.error('CraftMyPDF: Failed to stringify final request body for report ID ' + report_id + ':', rbErr);
            alert('Failed to prepare request body for CraftMyPDF. See console for details.');
            return;
        }

        // Log the exact API call details for debugging
        console.log('CraftMyPDF: API request ->', {
            url: requestUrl,
            method: 'POST',
            headers: requestHeaders,
            bodyPreview: (requestBody && requestBody.length > 2000) ? requestBody.substring(0,2000) + '... (truncated)' : requestBody,
            bodyLength: requestBody ? requestBody.length : 0
        });

        $.ajax({
            url: requestUrl,
            type: 'POST',
            headers: requestHeaders,
            contentType: 'application/json',
            data: requestBody,
            success: function(response) {
                console.log('CraftMyPDF: PDF generated for report ID ' + report_id + ': ', response);
                if (response.file) {
                    var existingDownload = $('#craftmypdf-download');
                    if (existingDownload.length) {
                        existingDownload.attr('href', response.file);
                        existingDownload.text('Download PDF');
                        existingDownload.off('click').on('click', function(e) {
                            e.preventDefault();
                            window.open(response.file, '_blank');
                        });
                    } else {
                        var downloadLink = $('<a>', {
                            id: 'craftmypdf-download',
                            href: response.file,
                            text: 'Download PDF',
                            class: 'btn btn-success',
                            style: 'margin: 10px;'
                        });
                        downloadLink.on('click', function(e) {
                            e.preventDefault();
                            window.open(response.file, '_blank');
                        });
                        $('#craftmypdf-button').after(downloadLink);
                    }
                    // Store PDF URL in database
                    $.ajax({
                        url: '/cgi-bin/koha/plugins/run.pl',
                        type: 'POST',
                        data: {
                            class: 'Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF',
                            method: 'store_pdf_url',
                            report_id: report_id,
                            pdf_url: response.file
                        },
                        success: function() {
                            console.log('CraftMyPDF: PDF URL stored for report ID ' + report_id);
                        },
                        error: function(xhr, status, error) {
                            console.error('CraftMyPDF: Failed to store PDF URL for report ID ' + report_id, status, error, xhr.responseText);
                        }
                    });
                } else {
                    console.error('CraftMyPDF: No file URL in response for report ID ' + report_id);
                    alert('Error generating PDF: No file URL returned');
                }
            },
            error: function(xhr, status, error) {
                console.error('CraftMyPDF: PDF generation failed for report ID ' + report_id, status, error, xhr.responseText);
                alert('Error generating PDF: ' + error);
            }
        });
    }

    // Try to extract a pure JSON substring from arbitrary text output using bracket matching.
    function extractJsonFromText(text) {
        if (!text) return null;
        var t = String(text).trim();

        // If the response is HTML-wrapped, try to extract the content of <pre>, <textarea>, or <code> first.
        try {
            if (/<\/\w+>/.test(t)) {
                var div = document.createElement('div');
                div.innerHTML = t;
                var pre = div.querySelector('pre, textarea, code');
                if (pre && pre.textContent && pre.textContent.trim()) {
                    t = pre.textContent.trim();
                } else {
                    // Fall back to textContent of the whole HTML
                    var txt = div.textContent || div.innerText || '';
                    if (txt && txt.trim()) { t = txt.trim(); }
                }
            }
        } catch (htmlErr) {
            // ignore and continue with original text
            console.warn('CraftMyPDF: HTML extraction encountered an error', htmlErr);
        }

        // Try parsing entire text first
        try {
            return JSON.parse(t);
        } catch (e) {
            // Continue to substring extraction
        }

        // Strategy: try a quick first/last brace substring grab, then fall back to robust bracket matching
        var firstBrace = t.search(/[\{\[]/);
        var lastCurl = t.lastIndexOf('}');
        var lastSquare = t.lastIndexOf(']');
        var lastBrace = Math.max(lastCurl, lastSquare);
        if (firstBrace !== -1 && lastBrace !== -1 && lastBrace > firstBrace) {
            var quickCandidate = t.substring(firstBrace, lastBrace + 1);
            try {
                return JSON.parse(quickCandidate);
            } catch (qErr) {
                console.warn('CraftMyPDF: Quick substring parse failed, will try robust extraction', qErr, quickCandidate.substring(0,200));
            }
        }

        // Robust bracket-matching extraction (respecting strings and escapes)
        var firstObj = t.indexOf('{');
        var firstArr = t.indexOf('[');
        if (firstObj === -1 && firstArr === -1) {
            console.error('CraftMyPDF: No JSON opening bracket found in text');
            console.debug('CraftMyPDF: Raw text (truncated):', t.substring(0,500));
            return null;
        }
        var start = (firstObj === -1 || (firstArr !== -1 && firstArr < firstObj)) ? firstArr : firstObj;

        var stack = [];
        var inString = false;
        var escape = false;
        var end = -1;

        for (var i = start; i < t.length; i++) {
            var ch = t[i];
            if (inString) {
                if (escape) { escape = false; continue; }
                if (ch === '\\') { escape = true; continue; }
                if (ch === '"') { inString = false; }
                continue;
            } else {
                if (ch === '"') { inString = true; continue; }
                if (ch === '{' || ch === '[') { stack.push(ch); continue; }
                if ((ch === '}' || ch === ']') && stack.length > 0) {
                    var last = stack.pop();
                    if (stack.length === 0) { end = i; break; }
                }
            }
        }

        if (start === -1 || end === -1 || end <= start) {
            console.error('CraftMyPDF: Could not locate matching JSON bounds in text');
            console.debug('CraftMyPDF: Raw text (truncated):', t.substring(0,1000));
            return null;
        }

        var candidate = t.substring(start, end + 1);
        try {
            return JSON.parse(candidate);
        } catch (e2) {
            console.error('CraftMyPDF: Failed to parse extracted JSON candidate', e2, 'candidate=', candidate.substring(0,1000));
            return null;
        }
    }

    function addCraftMyPDFButton(report_id) {
        if (buttonAdded || $('#craftmypdf-button').length > 0) {
            console.log('CraftMyPDF: Button already exists or added for report ID ' + report_id + ', skipping');
            return;
        }
        console.log('CraftMyPDF: Attempting to add button for report ID ' + report_id);
        $.ajax({
            url: '/cgi-bin/koha/plugins/run.pl',
            type: 'GET',
            data: {
                class: 'Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF',
                method: 'get_config',
                id: report_id
            },
            dataType: 'json',
            success: function(data) {
                console.log('CraftMyPDF: Config data for report ID ' + report_id + ' = ', data);
                if (!(data && data.api_key)) {
                    console.log('CraftMyPDF: No config (api_key missing) for report ID ' + report_id);
                    return;
                }

                var urlParams = new URLSearchParams(window.location.search);
                var params = {};
                urlParams.forEach((value, key) => {
                    if (key.startsWith('param_name') || key.startsWith('sql_params')) {
                        params[key] = value;
                    }
                });
                params.id = report_id;
                params.op = 'export';
                var isComplex = (data && data.complex_json && data.complex_json === '1');
                params.format = isComplex ? 'json' : 'csv';
                params._ = new Date().getTime();

                var hasTemplate = (data.template_id && data.template_id !== '');
                var button = $('<button>', {
                    id: 'craftmypdf-button',
                    text: hasTemplate ? 'Generate PDF' : 'Configure Template',
                    class: hasTemplate ? 'btn btn-primary' : 'btn btn-secondary',
                    style: 'margin: 10px;'
                });

                if (!hasTemplate) {
                    button.on('click', function() {
                        alert('No CraftMyPDF template is configured for this report.\n\nPlease open the CraftMyPDF plugin settings and assign a Template ID for report ' + report_id + '.');
                    });
                } else {
                    button.on('click', function() {
                        console.log('CraftMyPDF: Generate PDF button clicked for report ID ' + report_id + ', complex_json=' + isComplex);
                        if (isComplex) {
                            // Request report as text and attempt to extract pure JSON
                            $.ajax({
                                url: '/cgi-bin/koha/reports/guided_reports.pl',
                                type: 'GET',
                                data: params,
                                dataType: 'text',
                                cache: false,
                                success: function(textBody) {
                                    console.log('CraftMyPDF: Raw text received for report ID ' + report_id + ' = ', (textBody && textBody.substring) ? textBody.substring(0,200) + '...' : textBody);
                                    // If the server returned an empty body, try to find JSON already rendered on the page
                                    if (!textBody || (typeof textBody === 'string' && textBody.trim() === '')) {
                                        console.warn('CraftMyPDF: Empty textBody returned from guided_reports, attempting DOM fallback for JSON');
                                        var domCandidate = null;
                                        // Common places where JSON might be rendered
                                        var selectors = ['#report_results', '.reportresults', 'pre', 'code', 'textarea', '.report_content', '.reportdata', 'body'];
                                        for (var s=0; s<selectors.length && !domCandidate; s++) {
                                            try {
                                                var el = document.querySelector(selectors[s]);
                                                if (el && el.textContent) {
                                                    var txt = el.textContent.trim();
                                                    if (txt && (/^[\[\{]/.test(txt))) {
                                                        domCandidate = txt;
                                                        console.log('CraftMyPDF: Found candidate JSON in selector ' + selectors[s] + ' (truncated):', txt.substring(0,200));
                                                        break;
                                                    }
                                                }
                                            } catch (domErr) {
                                                // ignore selector errors
                                            }
                                        }
                                        // As a last resort, scan all <pre> and <code> blocks for JSON-like starts
                                        if (!domCandidate) {
                                            var blocks = document.querySelectorAll('pre, code, textarea, div, span');
                                            for (var i=0;i<blocks.length;i++) {
                                                try {
                                                    var t = (blocks[i].textContent || '').trim();
                                                    if (t && (/^[\[\{]/.test(t))) { domCandidate = t; console.log('CraftMyPDF: Found candidate JSON in DOM block (truncated):', t.substring(0,200)); break; }
                                                } catch (be) {}
                                            }
                                        }
                                        if (domCandidate) { textBody = domCandidate; }
                                    }

                                    var parsed = extractJsonFromText(textBody);
                                    if (!parsed) {
                                        console.error('CraftMyPDF: Failed to extract JSON from report text for report ID ' + report_id);
                                        alert('Failed to parse JSON report data. Ensure the report outputs valid JSON. Check the console/network tab for the full response.');
                                        return;
                                    }
                                    var payload = {
                                        template_id: data.template_id,
                                        export_type: 'json',
                                        output_file: 'report_' + report_id + '_' + new Date().toISOString().replace(/[:.]/g, '') + '.pdf',
                                        data: parsed
                                    };
                                    sendPayloadToCraft(parsed, payload, data.api_key, report_id);
                                },
                                error: function(xhr, status, error) {
                                    console.error('CraftMyPDF: Failed to fetch report text for report ID ' + report_id, status, error, xhr.responseText);
                                    alert('Error fetching report data: ' + error);
                                }
                            });
                        } else {
                            // Existing CSV -> JSON flow
                            $.ajax({
                                url: '/cgi-bin/koha/reports/guided_reports.pl',
                                type: 'GET',
                                data: params,
                                dataType: 'text',
                                cache: false,
                                success: function(csv) {
                                    console.log('CraftMyPDF: CSV data received for report ID ' + report_id + ' = ', (csv && csv.substring) ? csv.substring(0, 100) + '...' : csv);
                                    if (!csv || csv.trim() === '') {
                                        alert('No report data found');
                                        return;
                                    }
                                    var jsonData = csvToJson(csv, report_id);
                                    if (jsonData.length === 0) {
                                        jsonData = tableToJson(report_id);
                                    }
                                    if (jsonData.length === 0) {
                                        alert('Unable to parse report data due to formatting issues.');
                                        return;
                                    }
                                    var payload = {
                                        template_id: data.template_id,
                                        export_type: 'json',
                                        output_file: 'report_' + report_id + '_' + new Date().toISOString().replace(/[:.]/g, '') + '.pdf',
                                        data: { items: jsonData }
                                    };
                                    sendPayloadToCraft(jsonData, payload, data.api_key, report_id);
                                },
                                error: function(xhr, status, error) {
                                    console.error('CraftMyPDF: Failed to fetch CSV data for report ID ' + report_id, status, error, xhr.responseText);
                                    alert('Error fetching report data: ' + error);
                                }
                            });
                        }
                    });
                }

                // Append button to page
                var downloadBlock = $("#downloadblock, .downloadblock").first();
                if (downloadBlock.length > 0) {
                    downloadBlock.append(button);
                } else if ($(".report_number").length > 0) {
                    $(".report_number").parent().prepend(button);
                } else {
                    $("body").prepend(button);
                }
                buttonAdded = true;
                console.log('CraftMyPDF: Button added successfully for report ID ' + report_id);
            },
            error: function(xhr, status, error) {
                console.error('CraftMyPDF: Failed to fetch config for report ID ' + report_id, status, error, xhr.responseText);
            }
        });
    }

    $(document).ready(function() {
        console.log('CraftMyPDF: intranet_js loaded');
        if (/guided_reports\.pl.*op=run/.test(window.location.href)) {
            console.log('CraftMyPDF: On report results page');
            if ($('#report_param_form').length > 0) {
                console.log('CraftMyPDF: Parameter form detected, skipping button');
                return;
            }
            buttonAdded = false;
            var report_id = new URLSearchParams(window.location.search).get('id') || $('.report_number').text().trim();
            if (report_id) {
                console.log('CraftMyPDF: Using report ID ' + report_id);
                setTimeout(function() {
                    addCraftMyPDFButton(report_id);
                }, 1000);
            } else {
                console.error('CraftMyPDF: No valid report ID found');
            }
        } else {
            console.log('CraftMyPDF: Not on report results page');
            console.log('CraftMyPDF: URL = ' + window.location.href);
        }
    });
})();
</script>
END_JS
}

sub store_pdf_url {
    my ( $self ) = @_;
    my $cgi = $self->{'cgi'} || CGI->new;
    my $report_id = $cgi->param('report_id') || '';
    my $pdf_url = $cgi->param('pdf_url') || '';

    unless ($report_id && $pdf_url) {
        warn "CraftMyPDF: store_pdf_url failed - missing parameters: report_id=$report_id, pdf_url=$pdf_url";
        return $self->output_json(encode_json({ error => "Missing required parameters" }), 400);
    }

    my $dbh = C4::Context->dbh;
    eval {
        my $sth = $dbh->prepare("INSERT INTO koha_plugin_com_lightwavelibrary_craftmypdf_pdfs (report_id, pdf_url, expires_at) VALUES (?, ?, DATE_ADD(NOW(), INTERVAL 15 DAY))");
        $sth->execute($report_id, $pdf_url);
    };
    if ($@) {
        warn "CraftMyPDF: Database error in store_pdf_url for report_id $report_id: $@";
        return $self->output_json(encode_json({ error => "Database error: $@" }), 500);
    }
    warn "CraftMyPDF: PDF URL stored for report_id $report_id: $pdf_url";
    return $self->output_json(encode_json({ success => "PDF URL stored for report_id $report_id" }));
}

sub get_config {
    my ( $self ) = @_;
    my $cgi = $self->{'cgi'} || CGI->new;
    my $report_id = $cgi->param('id') || '';
    unless ($report_id) {
        warn "CraftMyPDF: get_config failed - no report_id provided";
        return $self->output_json(encode_json({ error => "No report_id provided" }), 400);
    }

    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("SELECT report_id, webhook, api_key, template_id, COALESCE(complex_json, '0') AS complex_json FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs WHERE report_id = ?");
    eval {
        $sth->execute($report_id);
    };
    if ($@) {
        warn "CraftMyPDF: Database error in get_config for report_id $report_id: $@";
        return $self->output_json(encode_json({ error => "Database error: $@" }), 500);
    }

    my $row = $sth->fetchrow_hashref;
    if ($row) {
        # If the per-config api_key is empty, fall back to plugin-level stored api_key
        if (!$row->{api_key} || $row->{api_key} eq '') {
            my $global_api_key = $self->retrieve_data('api_key') || '';
            $row->{api_key} = $global_api_key;
        }
        warn "CraftMyPDF: Config found for report_id $report_id: " . encode_json($row);
        return $self->output_json(encode_json($row));
    } else {
        warn "CraftMyPDF: No config found for report_id $report_id";
        return $self->output_json(encode_json({}));
    }
}

sub output_json {
    my ( $self, $json, $status ) = @_;
    my $cgi = $self->{'cgi'} || CGI->new;
    print $cgi->header(
        -type   => 'application/json',
        -status => $status || 200,
    );
    print $json;
}

sub install {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    eval {
            my $sth = $dbh->prepare("SELECT 1 FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
        $sth->execute();
    };
    if ($@) {
        $dbh->do(q{
            CREATE TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs (
                id INT AUTO_INCREMENT PRIMARY KEY,
                report_id VARCHAR(255) NOT NULL,
                webhook TEXT,
                api_key TEXT NOT NULL,
                    template_id VARCHAR(255) DEFAULT '',
                    complex_json VARCHAR(1) DEFAULT '0'
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        });
    } else {
        eval {
            my $sth = $dbh->prepare("SELECT template_id FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
            $sth->execute();
        };
        if ($@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs ADD COLUMN template_id VARCHAR(255) DEFAULT '' AFTER api_key");
        }
        # ensure complex_json exists
        eval {
            my $sth = $dbh->prepare("SELECT complex_json FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
            $sth->execute();
        };
        if ($@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs ADD COLUMN complex_json VARCHAR(1) DEFAULT '0' AFTER template_id");
        }
        eval {
            my $sth = $dbh->prepare("SELECT primary_email FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
            $sth->execute();
        };
        if (!$@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs DROP COLUMN primary_email, DROP COLUMN cc_email");
        }
        # structure_determined column removed from schema; no action required
    }
    eval {
        my $sth = $dbh->prepare("SELECT 1 FROM koha_plugin_com_lightwavelibrary_craftmypdf_pdfs LIMIT 1");
        $sth->execute();
    };
    if ($@) {
        $dbh->do(q{
            CREATE TABLE koha_plugin_com_lightwavelibrary_craftmypdf_pdfs (
                id INT AUTO_INCREMENT PRIMARY KEY,
                report_id VARCHAR(255) NOT NULL,
                pdf_url TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                expires_at DATETIME NOT NULL
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        });
    } else {
        eval {
            my $sth = $dbh->prepare("SELECT task_id FROM koha_plugin_com_lightwavelibrary_craftmypdf_pdfs LIMIT 1");
            $sth->execute();
        };
        if (!$@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_pdfs DROP COLUMN task_id");
        }
    }
    $self->store_data({ '__INSTALLED__' => 1, '__INSTALLED_VERSION__' => $VERSION });
    return 1;
}

sub upgrade {
    my ( $self ) = @_;
    my $dbh = C4::Context->dbh;
    eval {
        my $sth = $dbh->prepare("SELECT 1 FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
        $sth->execute();
    };
    if ($@) {
        $dbh->do(q{
            CREATE TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs (
                id INT AUTO_INCREMENT PRIMARY KEY,
                report_id VARCHAR(255) NOT NULL,
                webhook TEXT,
                api_key TEXT NOT NULL,
                template_id VARCHAR(255) DEFAULT ''
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        });
    } else {
        eval {
            my $sth = $dbh->prepare("SELECT template_id FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
            $sth->execute();
        };
        if ($@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs ADD COLUMN template_id VARCHAR(255) DEFAULT '' AFTER api_key");
        }
        eval {
            my $sth = $dbh->prepare("SELECT primary_email FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
            $sth->execute();
        };
        if (!$@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs DROP COLUMN primary_email, DROP COLUMN cc_email");
        }
        # If an old 'expiration' column exists, drop it (idempotent)
        eval {
            my $sth = $dbh->prepare("SELECT expiration FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
            $sth->execute();
        };
        if (!$@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs DROP COLUMN expiration");
        }
        eval {
            my $sth = $dbh->prepare("SELECT structure_determined FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
            $sth->execute();
        };
        if (!$@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs DROP COLUMN structure_determined");
        }
    }
    eval {
        my $sth = $dbh->prepare("SELECT 1 FROM koha_plugin_com_lightwavelibrary_craftmypdf_pdfs LIMIT 1");
        $sth->execute();
    };
    if ($@) {
        $dbh->do(q{
            CREATE TABLE koha_plugin_com_lightwavelibrary_craftmypdf_pdfs (
                id INT AUTO_INCREMENT PRIMARY KEY,
                report_id VARCHAR(255) NOT NULL,
                pdf_url TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                expires_at DATETIME NOT NULL
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        });
    } else {
        eval {
            my $sth = $dbh->prepare("SELECT task_id FROM koha_plugin_com_lightwavelibrary_craftmypdf_pdfs LIMIT 1");
            $sth->execute();
        };
        if (!$@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_pdfs DROP COLUMN task_id");
        }
    }
    return 1;
}

sub uninstall {
    my ( $self ) = @_;
    my $delete_on_uninstall = $self->retrieve_data('delete_on_uninstall') || '0';
    if ($delete_on_uninstall eq '1') {
        my $dbh = C4::Context->dbh;
        $dbh->do("DROP TABLE IF EXISTS koha_plugin_com_lightwavelibrary_craftmypdf_configs");
        $dbh->do("DROP TABLE IF EXISTS koha_plugin_com_lightwavelibrary_craftmypdf_pdfs");
        $self->store_data({ '__INSTALLED__' => 0, '__INSTALLED_VERSION__' => undef, 'api_key' => undef, 'delete_on_uninstall' => undef });
    } else {
        $self->store_data({ '__INSTALLED__' => 0, '__INSTALLED_VERSION__' => undef });
    }
    return 1;
}

1;
